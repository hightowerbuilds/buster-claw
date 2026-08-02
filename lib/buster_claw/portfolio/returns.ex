defmodule BusterClaw.Portfolio.Returns do
  @moduledoc """
  The gain arithmetic, as pure functions of the rows handed to it.

  Nothing here reads the database or the clock. `Portfolio` fetches; this module
  decides what the numbers MEAN — which is the half that has to be right, and
  the half that was previously only reachable by writing snapshot rows first.

  Three pieces of arithmetic live here, and each one exists because a naive
  version of it would quietly lie:

    * **`build_gain_series/2`** measures gain *around* flows, so a deposit never
      reads as a return.
    * **`anomalous?/1`** flags a day that moved like a transfer, behind a floor
      so a percentage alone can't flag every wobble in a small account.
    * **`join_series/2`** splices the broker's realized history onto our own
      recorded series without counting the overlap twice, and offsets the
      recorded segment so the seam is continuous rather than a cliff.
  """

  alias BusterClaw.Portfolio.RealizedPoint

  @anomaly_ratio 0.2
  @anomaly_floor_cents 10_000

  @doc "Flows collapsed to `%{Date.t() => cents}`, summing same-day entries."
  def flows_by_day(flows) do
    Enum.reduce(flows, %{}, fn flow, acc ->
      Map.update(acc, flow.occurred_on, flow.amount_cents, &(&1 + flow.amount_cents))
    end)
  end

  @doc """
  Fold `[%{day, value_cents}]` (oldest first) into the gain series.

  `gain_cents` is `nil` for the first reading: there is no earlier value to
  measure against, and a first point of "zero gain" would be a claim we can't
  support. Cumulative starts at zero there and folds forward.

      gain[d] = value[d] − value[prev] − Σ flows in (prev, d]
  """
  def build_gain_series([], _flows), do: []

  def build_gain_series([first | rest], flows) do
    initial = %{
      day: first.day,
      value_cents: first.value_cents,
      gain_cents: nil,
      flow_cents: Map.get(flows, first.day, 0),
      cumulative_cents: 0
    }

    {points, _} =
      Enum.map_reduce(rest, initial, fn point, prev ->
        flow_cents = flow_between(flows, prev.day, point.day)
        gain = point.value_cents - prev.value_cents - flow_cents

        current = %{
          day: point.day,
          value_cents: point.value_cents,
          gain_cents: gain,
          flow_cents: flow_cents,
          cumulative_cents: prev.cumulative_cents + gain
        }

        {current, current}
      end)

    [initial | points]
  end

  # Flows in (prev, day] — open at `prev` and closed at `day`, because a flow
  # dated `d` is assumed to be reflected in `d`'s reading. Spanning from the
  # previous RECORDED day rather than the previous calendar day is what keeps a
  # flow landing inside a recording gap subtracted exactly once.
  defp flow_between(flows, prev_day, day) do
    flows
    |> Enum.filter(fn {flow_day, _cents} ->
      Date.compare(flow_day, prev_day) == :gt and Date.compare(flow_day, day) != :gt
    end)
    |> Enum.map(fn {_day, cents} -> cents end)
    |> Enum.sum()
  end

  @doc """
  Does this point's move look like an unmarked transfer?

  Flagged when the raw change is at least #{trunc(@anomaly_ratio * 100)}% of the
  previous value **and** at least #{div(@anomaly_floor_cents, 100)} dollars. The
  floor exists because a percentage alone would flag every ordinary wobble in a
  small account.
  """
  def anomalous?(%{gain_cents: gain, value_cents: value}) do
    magnitude = abs(gain)
    previous = value - gain

    magnitude >= @anomaly_floor_cents and previous > 0 and
      magnitude / previous >= @anomaly_ratio
  end

  @doc """
  Splice the realized (pre-recording) segment onto the recorded one.

  The seam is the recorded series' first day: realized buckets on or after it
  are dropped, because keeping them would count the same days twice. The
  recorded segment is then offset by the realized total so the line is
  continuous — the two measures share a unit, and a jump at the seam would read
  as a gain nobody made.
  """
  def join_series(points, recorded) do
    seam = recorded |> List.first() |> then(&(&1 && &1.day))

    realized =
      points
      |> drop_from_seam(seam)
      |> Enum.scan(0, fn point, running -> running + realized_cents_of(point) end)
      |> Enum.zip(drop_from_seam(points, seam))
      |> Enum.map(fn {cumulative, point} ->
        %{
          day: bucket_day(point),
          cumulative_cents: cumulative,
          measure: :realized,
          gain_cents: realized_cents_of(point),
          value_cents: nil,
          flow_cents: 0
        }
      end)

    offset = realized |> List.last() |> then(&((&1 && &1.cumulative_cents) || 0))

    recorded_points =
      Enum.map(recorded, fn point ->
        %{
          day: point.day,
          cumulative_cents: offset + point.cumulative_cents,
          measure: :recorded,
          gain_cents: point.gain_cents,
          value_cents: point.value_cents,
          # Carried through so the chart can MARK the day. A deposit that was
          # netted out of the gain is invisible in the line by design; a reader
          # who can't see it was there has no way to check the arithmetic.
          flow_cents: Map.get(point, :flow_cents, 0)
        }
      end)

    realized ++ recorded_points
  end

  defp drop_from_seam(points, nil), do: points

  defp drop_from_seam(points, seam),
    do: Enum.filter(points, &(Date.compare(bucket_day(&1), seam) == :lt))

  defp bucket_day(%RealizedPoint{bucket_on: day}), do: day
  defp bucket_day(%{day: day}), do: day

  defp realized_cents_of(%RealizedPoint{realized_cents: cents}), do: cents
  defp realized_cents_of(%{realized_cents: cents}), do: cents
end
