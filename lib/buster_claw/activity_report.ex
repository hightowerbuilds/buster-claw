defmodule BusterClaw.ActivityReport do
  @moduledoc """
  The "what your agent did" report — totals and time-series — built **directly
  from the durable audit trail**, so the numbers can't drift from reality:

    * `security_events` (the append-only Sentinel feed) — every headless **run**
      and every consequential **command** the agent executed.
    * `dispatch_items` (the durable queue) — work **handled** and still **open**.

  There is deliberately no snapshot/rollup table: aggregating the source-of-truth
  on read means a reload always reflects exactly what happened. Queries hit clean
  indexed columns (`category`/`inserted_at`, `status`/`finished_at`), grouped by
  day in SQL and folded into the requested granularity in Elixir.

  ## Metric definitions

    * `runs`     — headless agent runs (chat + unattended); `command_invoke`
      events whose message contains "agent run".
    * `commands` — consequential commands the agent invoked through the surface;
      `command_invoke` events that are *not* run summaries.
    * `handled`  — dispatch items finished `done`.
    * `open`     — dispatch items currently queued/claimed/running (point-in-time).
  """

  import Ecto.Query

  alias BusterClaw.Dispatch.Item
  alias BusterClaw.Repo
  alias BusterClaw.Sentinel.Event

  @default_days 7
  @open_statuses ~w(queued claimed running)
  @run_pattern "%agent run%"

  @months {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

  # How many buckets each granularity shows.
  @grains %{"day" => {:day, 14}, "week" => {:week, 12}, "month" => {:month, 12}}

  @doc "Granularity keys the timeline accepts."
  def grains, do: ~w(day week month)

  @doc """
  Flat totals over the last `:days` days (default #{@default_days}). `:now` may be
  supplied for deterministic windows (tests).
  """
  def summary(opts \\ []) do
    days = Keyword.get(opts, :days, @default_days)
    now = (Keyword.get(opts, :now) || DateTime.utc_now()) |> DateTime.truncate(:second)
    since = DateTime.add(now, -days * 86_400, :second)

    %{
      days: days,
      since: since,
      until: now,
      handled: count_finished(since, now, "done"),
      blocked: count_finished(since, now, "blocked"),
      failed: count_finished(since, now, "failed"),
      open: count_open(),
      runs: count_events(since, now, :runs),
      commands: count_events(since, now, :commands)
    }
  end

  @doc """
  Time-series for graphing at `grain` (`"day" | "week" | "month"`).

  Returns `%{grain, buckets: [%{key, label, runs, commands, handled}], totals}`,
  oldest bucket first, with empty buckets filled in as zeros so the chart has a
  continuous x-axis. `:today` may be supplied for deterministic windows.
  """
  def timeline(grain, opts \\ []) when grain in ["day", "week", "month"] do
    {unit, count} = Map.fetch!(@grains, grain)
    today = Keyword.get(opts, :today) || Date.utc_today()
    buckets = build_buckets(unit, count, today)

    since = buckets |> List.first() |> Map.fetch!(:first) |> day_start()
    until = today |> day_end()

    runs = daily_counts(:runs, since, until)
    commands = daily_counts(:commands, since, until)
    handled = daily_counts(:handled, since, until)

    rows =
      Enum.map(buckets, fn b ->
        %{
          key: b.key,
          label: b.label,
          runs: sum_range(runs, b.first, b.last),
          commands: sum_range(commands, b.first, b.last),
          handled: sum_range(handled, b.first, b.last)
        }
      end)

    %{
      grain: grain,
      buckets: rows,
      totals: %{
        runs: sum_metric(rows, :runs),
        commands: sum_metric(rows, :commands),
        handled: sum_metric(rows, :handled),
        open: count_open()
      }
    }
  end

  # ---- flat counts ----

  defp count_finished(since, until, status) do
    Repo.aggregate(
      from(i in Item,
        where: i.status == ^status and i.finished_at >= ^since and i.finished_at <= ^until
      ),
      :count
    )
  end

  defp count_open do
    Repo.aggregate(from(i in Item, where: i.status in @open_statuses), :count)
  end

  defp count_events(since, until, kind) do
    Repo.aggregate(events_in_window(kind, since, until), :count)
  end

  defp events_in_window(:runs, since, until) do
    from(e in Event,
      where:
        e.category == "command_invoke" and e.inserted_at >= ^since and e.inserted_at <= ^until and
          like(e.message, ^@run_pattern)
    )
  end

  defp events_in_window(:commands, since, until) do
    from(e in Event,
      where:
        e.category == "command_invoke" and e.inserted_at >= ^since and e.inserted_at <= ^until and
          not like(e.message, ^@run_pattern)
    )
  end

  # ---- daily series (grouped in SQL, folded in Elixir) ----

  defp daily_counts(:handled, since, until) do
    from(i in Item,
      where: i.status == "done" and i.finished_at >= ^since and i.finished_at <= ^until,
      group_by: fragment("date(?)", i.finished_at),
      select: {fragment("date(?)", i.finished_at), count(i.id)}
    )
    |> to_day_map()
  end

  defp daily_counts(kind, since, until) do
    events_in_window(kind, since, until)
    |> group_by([e], fragment("date(?)", e.inserted_at))
    |> select([e], {fragment("date(?)", e.inserted_at), count(e.id)})
    |> to_day_map()
  end

  defp to_day_map(query) do
    query
    |> Repo.all()
    |> Map.new(fn {date_str, n} -> {Date.from_iso8601!(date_str), n} end)
  end

  defp sum_range(day_map, first, last) do
    day_map
    |> Enum.filter(fn {d, _} ->
      Date.compare(d, first) != :lt and Date.compare(d, last) != :gt
    end)
    |> Enum.reduce(0, fn {_, n}, acc -> acc + n end)
  end

  defp sum_metric(rows, key), do: Enum.reduce(rows, 0, fn r, acc -> acc + Map.fetch!(r, key) end)

  # ---- bucket construction ----

  defp build_buckets(:day, count, today) do
    for i <- (count - 1)..0//-1 do
      d = Date.add(today, -i)
      %{key: Date.to_iso8601(d), label: md_label(d), first: d, last: d}
    end
  end

  defp build_buckets(:week, count, today) do
    anchor = Date.beginning_of_week(today)

    for i <- (count - 1)..0//-1 do
      first = Date.add(anchor, -i * 7)

      %{
        key: Date.to_iso8601(first),
        label: md_label(first),
        first: first,
        last: Date.add(first, 6)
      }
    end
  end

  defp build_buckets(:month, count, today) do
    base = today.year * 12 + (today.month - 1)

    for i <- (count - 1)..0//-1 do
      total = base - i
      year = div(total, 12)
      month = rem(total, 12) + 1
      first = Date.new!(year, month, 1)

      %{
        key: "#{year}-#{month}",
        label: elem(@months, month - 1),
        first: first,
        last: Date.end_of_month(first)
      }
    end
  end

  defp md_label(%Date{} = d), do: "#{d.month}/#{d.day}"

  defp day_start(%Date{} = d), do: DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
  defp day_end(%Date{} = d), do: DateTime.new!(d, ~T[23:59:59], "Etc/UTC")
end
