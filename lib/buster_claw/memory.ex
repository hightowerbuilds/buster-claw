defmodule BusterClaw.Memory do
  @moduledoc """
  Cross-run memory (Phase 2). Persists a structured `RunSummary` for each headless
  agent run and exposes full-text recall over them via SQLite FTS5, so a later run
  can answer "what have I done with X before?".

  Tier mapping (see daily-growth/research/s0.3-hermes-4tier-memory.md): Tier 1 is the
  per-conversation chat transcript (`Agent.Transcript`); this module is Tier 2 —
  searchable run history. Tiers 3/4 (durable agent notes, user model) are out of
  scope for v1.
  """
  import Ecto.Query

  require Logger

  alias BusterClaw.Memory.RunSummary
  alias BusterClaw.Repo

  @doc """
  Record a run summary (best-effort — recording must never break the run it
  describes). Returns `{:ok, summary}` or `{:error, reason}`.
  """
  def record_run(attrs) do
    %RunSummary{} |> RunSummary.changeset(normalize(attrs)) |> Repo.insert()
  rescue
    error ->
      Logger.warning("Memory.record_run failed: #{inspect(error)}")
      {:error, error}
  end

  @doc "The most recent run summaries, newest first."
  def recent(limit \\ 20) do
    RunSummary
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Full-text search across run summaries (FTS5 over goal/detail/outcome), ranked by
  relevance (bm25). Returns `{:ok, [summary]}` or `{:error, :empty_query}` when the
  query has no searchable terms.
  """
  def search(query, opts \\ []) do
    case build_match(query) do
      :empty ->
        {:error, :empty_query}

      match ->
        limit = Keyword.get(opts, :limit, 20)

        # FTS5 returns rowids ranked by `rank`; load the structured rows and
        # restore that order (a plain `WHERE id IN` would lose the ranking).
        %{rows: rows} =
          Repo.query!(
            "SELECT rowid FROM run_summaries_fts WHERE run_summaries_fts MATCH ? ORDER BY rank LIMIT ?",
            [match, limit]
          )

        ids = Enum.map(rows, fn [id] -> id end)
        by_id = RunSummary |> where([r], r.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})
        {:ok, Enum.flat_map(ids, fn id -> List.wrap(Map.get(by_id, id)) end)}
    end
  end

  # Build a safe FTS5 MATCH expression: extract alphanumeric terms, quote each (so
  # punctuation/operators in user input can't break FTS5 syntax), and OR them for
  # broad recall — bm25 `rank` then orders by relevance.
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

  # Stringify the string-typed fields so callers can pass atoms — `agent` is
  # `:claude`/`:codex`, `provenance` is `:trusted`/`:untrusted`, etc.
  defp normalize(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.update("agent", nil, &maybe_to_string/1)
    |> Map.update("provenance", nil, &maybe_to_string/1)
    |> Map.update("outcome", nil, &maybe_to_string/1)
    |> Map.update("source", "dispatch", &maybe_to_string/1)
  end

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(v) when is_binary(v), do: v
  defp maybe_to_string(v), do: to_string(v)
end
