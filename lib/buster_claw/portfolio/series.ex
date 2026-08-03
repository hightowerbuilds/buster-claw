defmodule BusterClaw.Portfolio.Series do
  @moduledoc """
  Windowing and re-zeroing for the cumulative gain/loss series — the math the
  chart and the `portfolio_history` command must share, because the two
  surfaces read the same ledger and must not disagree about what a number
  means.

  Lived in `BusterClawWeb.PortfolioChart` until 08-02, which made a command
  module depend on a web component — the last core→web edge holding the
  codebase's 72-file dependency cycle together. Pure functions of their
  arguments; the chart keeps delegates.
  """

  @ranges [
    {"1W", 7},
    {"1M", 31},
    {"3M", 93},
    {"1Y", 366},
    {"ALL", nil}
  ]

  def ranges, do: @ranges

  @doc "Trim a series to the selected range, counting back from its last point."
  def window(series, range) do
    case Enum.find(@ranges, fn {name, _days} -> name == range end) do
      {_name, nil} ->
        series

      {_name, days} ->
        case List.last(series) do
          nil ->
            series

          last ->
            cutoff = Date.add(last.day, -days)
            Enum.filter(series, &(Date.compare(&1.day, cutoff) != :lt))
        end

      nil ->
        series
    end
  end

  @doc """
  Re-zero a window so the line measures change *across the readings shown*.

  Without this the line always read cumulative-since-inception, so selecting
  "1M" still showed a figure accumulated over two and a half years — dominated,
  in the operator's own data, by an account that now holds $0 and did its
  trading in early 2025. Both numbers were true; together they were unreadable,
  and the range control looked broken (reported 07-28).

  The baseline is the **first visible point**, not the last one before the
  window. That distinction only bites while the data is sparse, and then it
  bites hard: with monthly backfill buckets and a single recorded day, measuring
  from the previous point credited sixteen months of recovery to "past month".
  Measuring across what is actually on screen cannot do that. Once daily
  recording accumulates the two converge, because the previous point is
  yesterday.

  "ALL" is left alone — nothing precedes it, and its first point already steps
  from an implicit zero, so re-zeroing would erase that first bucket's result.
  """
  def rebase([], _series), do: []

  def rebase([first | _] = windowed, series) do
    baseline = if windowed_from?(series, first.day), do: first.cumulative_cents, else: 0
    Enum.map(windowed, &Map.update!(&1, :cumulative_cents, fn cents -> cents - baseline end))
  end

  # True when the series carries history the window is cutting away.
  defp windowed_from?(series, first_day),
    do: Enum.any?(series, &(Date.compare(&1.day, first_day) == :lt))
end
