defmodule BusterClaw.BrowserHistory do
  @moduledoc """
  Recent in-app browser destinations for the `/browse` homepage. DB-backed
  (`browser_history_entries`): one row per visit, newest first. Records both
  external URLs and workspace files opened via the address bar (the native chrome
  toolbar posts each navigation here).

  Unlike the old JSON file this keeps **every** visit — no URL-dedupe — so revisit
  frequency is real and queryable (`visit_count/1`, `search/1`, `grouped_by_day/0`).
  Retention is bounded to the newest `max_entries/0` rows (default 10 000): every
  insert prunes anything older so the table can't grow without limit, while still
  keeping far more than any UI renders.
  """
  import Ecto.Query

  require Logger

  alias BusterClaw.BrowserHistory.Entry
  alias BusterClaw.Repo

  @default_limit 200
  @default_max_entries 10_000

  @doc """
  Recent entries, newest first. Returns `%Entry{}` structs (fields `:url`,
  `:title`, `:visited_at`). Capped at `limit` for display; pass a larger limit or
  `:infinity` to load everything.
  """
  def list(limit \\ @default_limit) do
    Entry
    |> order_by(desc: :visited_at, desc: :id)
    |> maybe_limit(limit)
    |> Repo.all()
  end

  @doc """
  Distinct recent destinations, newest first — one row per URL (its most recent
  visit). This is what the homepage "Recent" list renders: `list/0` keeps every
  visit for frequency/search, but a display list shouldn't repeat the same URL.
  """
  def recent(limit \\ 50) do
    # The newest visit of each URL is the row with the largest id for that URL
    # (ids are monotonic with insertion). Load those rows, newest first.
    latest_ids = from(e in Entry, group_by: e.url, select: max(e.id))

    Entry
    |> where([e], e.id in subquery(latest_ids))
    |> order_by(desc: :visited_at, desc: :id)
    |> maybe_limit(limit)
    |> Repo.all()
  end

  @doc """
  Record a visited URL (with a display title). Best-effort — a failed write is
  logged, never raised, so it can't break the navigation that triggered it.
  Returns `{:ok, %Entry{}}`, `{:error, reason}`, or `:ok` for ignored/blank urls.
  """
  def record(url, title \\ nil)

  def record(url, title) when is_binary(url) and url != "" do
    title = if is_binary(title) and String.trim(title) != "", do: title, else: url

    attrs = %{
      url: url,
      title: title,
      visited_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case %Entry{} |> Entry.changeset(attrs) |> Repo.insert() do
      {:ok, entry} ->
        prune()
        {:ok, entry}

      {:error, changeset} ->
        Logger.warning("BrowserHistory.record failed: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  rescue
    error ->
      Logger.warning("BrowserHistory.record crashed: #{inspect(error)}")
      {:error, error}
  end

  def record(_url, _title), do: :ok

  @doc """
  Full-text search across history (FTS5 over url + title), ranked by relevance
  (bm25). Returns `{:ok, [%Entry{}]}` or `{:error, :empty_query}` when the query
  has no searchable terms.
  """
  def search(query, opts \\ []) do
    case build_match(query) do
      :empty ->
        {:error, :empty_query}

      match ->
        limit = Keyword.get(opts, :limit, 50)

        # FTS5 returns rowids ranked by `rank`; load the structured rows and
        # restore that order (a plain `WHERE id IN` would lose the ranking).
        %{rows: rows} =
          Repo.query!(
            "SELECT rowid FROM browser_history_entries_fts WHERE browser_history_entries_fts MATCH ? ORDER BY rank LIMIT ?",
            [match, limit]
          )

        ids = Enum.map(rows, fn [id] -> id end)
        by_id = Entry |> where([e], e.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})
        {:ok, Enum.flat_map(ids, fn id -> List.wrap(Map.get(by_id, id)) end)}
    end
  end

  @doc """
  History grouped by calendar day (UTC), newest day first and newest entry first
  within each day. Returns `[{%Date{}, [%Entry{}]}]`.
  """
  def grouped_by_day(limit \\ @default_limit) do
    list(limit)
    |> Enum.group_by(&DateTime.to_date(&1.visited_at))
    |> Enum.sort_by(fn {date, _} -> date end, {:desc, Date})
  end

  @doc "How many times `url` has been visited."
  def visit_count(url) when is_binary(url) do
    Repo.aggregate(from(e in Entry, where: e.url == ^url), :count, :id)
  end

  @doc """
  Per-URL visit counts, most-visited first: `[{url, count}]`. Useful for a
  \"frequently visited\" view.
  """
  def visit_counts(limit \\ 50) do
    Entry
    |> group_by([e], e.url)
    |> select([e], {e.url, count(e.id)})
    |> order_by([e], desc: count(e.id))
    |> maybe_limit(limit)
    |> Repo.all()
  end

  @doc "Delete every history row. Returns the number deleted."
  def clear do
    {count, _} = Repo.delete_all(Entry)
    count
  end

  @doc """
  Delete history rows whose `visited_at` falls within `from..to` inclusive
  (both `DateTime`). Returns the number deleted.
  """
  def clear_range(%DateTime{} = from, %DateTime{} = to) do
    {count, _} =
      Entry
      |> where([e], e.visited_at >= ^from and e.visited_at <= ^to)
      |> Repo.delete_all()

    count
  end

  @doc "Retention cap: the most rows kept before older visits are pruned."
  def max_entries,
    do: Application.get_env(:buster_claw, :browser_history_max_entries, @default_max_entries)

  # Bounded retention: keep only the newest `max_entries/0` rows. The kept set is
  # the newest ids exactly (gap-immune, unlike id arithmetic), and the delete
  # trigger keeps the FTS index in sync. Runs after each insert; navigations are
  # human-paced, so the per-insert cost is negligible for a local history.
  defp prune do
    keep = from(e in Entry, order_by: [desc: e.id], limit: ^max_entries(), select: e.id)
    Entry |> where([e], e.id not in subquery(keep)) |> Repo.delete_all()
  rescue
    error -> Logger.warning("BrowserHistory.prune crashed: #{inspect(error)}")
  end

  defp maybe_limit(query, :infinity), do: query
  defp maybe_limit(query, limit) when is_integer(limit), do: limit(query, ^limit)

  # Build a safe FTS5 MATCH expression: extract alphanumeric terms, quote each
  # (so punctuation/operators in user input can't break FTS5 syntax), and OR them
  # for broad recall — bm25 `rank` then orders by relevance.
  defp build_match(query) do
    terms =
      query
      |> to_string()
      |> String.downcase()
      |> then(&Regex.scan(~r/[a-z0-9]+/, &1))
      |> List.flatten()

    case terms do
      [] -> :empty
      ts -> Enum.map_join(ts, " OR ", &~s("#{&1}"))
    end
  end
end
