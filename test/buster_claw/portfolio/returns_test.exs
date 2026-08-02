defmodule BusterClaw.Portfolio.ReturnsTest do
  @moduledoc """
  The gain arithmetic, tested without writing a snapshot row.

  These assertions are the ones that matter most and were previously the most
  expensive to make: that a deposit never reads as a return, that the seam
  between the broker's realized history and our own recording is continuous,
  and that a flow landing inside a recording gap is subtracted exactly once.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Portfolio.RealizedPoint
  alias BusterClaw.Portfolio.Returns

  defp d(iso), do: Date.from_iso8601!(iso)
  defp point(day, cents), do: %{day: d(day), value_cents: cents}
  defp flow(day, cents), do: %{occurred_on: d(day), amount_cents: cents}

  describe "flows_by_day/1" do
    test "sums same-day flows into one entry" do
      flows = [flow("2026-01-02", 500), flow("2026-01-02", 250), flow("2026-01-03", -100)]

      assert Returns.flows_by_day(flows) == %{
               d("2026-01-02") => 750,
               d("2026-01-03") => -100
             }
    end

    test "no flows is an empty map, not nil" do
      assert Returns.flows_by_day([]) == %{}
    end
  end

  describe "build_gain_series/2 — a deposit is not a gain" do
    test "the first reading has no gain, because there is nothing to measure against" do
      [first] = Returns.build_gain_series([point("2026-01-02", 10_000)], %{})

      assert first.gain_cents == nil
      assert first.cumulative_cents == 0
      assert first.value_cents == 10_000
    end

    test "an empty series stays empty" do
      assert Returns.build_gain_series([], %{}) == []
    end

    test "a pure market move is all gain" do
      series =
        Returns.build_gain_series(
          [point("2026-01-02", 10_000), point("2026-01-03", 11_000)],
          %{}
        )

      assert [_first, second] = series
      assert second.gain_cents == 1_000
      assert second.cumulative_cents == 1_000
    end

    test "a deposit is netted out — the headline number of this whole module" do
      series =
        Returns.build_gain_series(
          [point("2026-01-02", 10_000), point("2026-01-03", 15_000)],
          %{d("2026-01-03") => 5_000}
        )

      assert [_first, second] = series
      assert second.gain_cents == 0, "a $50 deposit must not read as a $50 gain"
      assert second.flow_cents == 5_000
      assert second.cumulative_cents == 0
    end

    test "a withdrawal is added back rather than counted as a loss" do
      series =
        Returns.build_gain_series(
          [point("2026-01-02", 10_000), point("2026-01-03", 5_000)],
          %{d("2026-01-03") => -5_000}
        )

      assert [_first, second] = series
      assert second.gain_cents == 0
    end

    test "cumulative folds forward across several days" do
      series =
        Returns.build_gain_series(
          [
            point("2026-01-02", 10_000),
            point("2026-01-03", 11_000),
            point("2026-01-04", 10_500)
          ],
          %{}
        )

      assert Enum.map(series, & &1.cumulative_cents) == [0, 1_000, 500]
      assert Enum.map(series, & &1.gain_cents) == [nil, 1_000, -500]
    end

    test "a flow inside a recording GAP is subtracted exactly once" do
      # Nothing recorded on the 3rd or 4th; the deposit landed on the 3rd.
      series =
        Returns.build_gain_series(
          [point("2026-01-02", 10_000), point("2026-01-05", 15_000)],
          %{d("2026-01-03") => 5_000}
        )

      assert [_first, second] = series
      assert second.gain_cents == 0
      assert second.flow_cents == 5_000
    end

    test "the window is open at the previous day — a flow ON it belongs to the earlier point" do
      series =
        Returns.build_gain_series(
          [point("2026-01-02", 10_000), point("2026-01-03", 10_000)],
          %{d("2026-01-02") => 5_000}
        )

      assert [first, second] = series
      assert first.flow_cents == 5_000
      assert second.flow_cents == 0, "a flow dated on the previous reading is already in it"
      assert second.gain_cents == 0
    end
  end

  describe "anomalous?/1 — ratio AND floor" do
    test "a big relative move above the floor is flagged" do
      # previous 100_000, gain 25_000 => 25%, well over the $100 floor
      assert Returns.anomalous?(%{gain_cents: 25_000, value_cents: 125_000})
    end

    test "a big relative move BELOW the dollar floor is not flagged" do
      # previous 200, gain 100 => 50%, but only $1
      refute Returns.anomalous?(%{gain_cents: 100, value_cents: 300})
    end

    test "a large dollar move that is small in relative terms is not flagged" do
      # $1,000 into a $200,000 account — the documented honest limit
      refute Returns.anomalous?(%{gain_cents: 100_000, value_cents: 20_100_000})
    end

    test "withdrawals are flagged too — magnitude is absolute" do
      assert Returns.anomalous?(%{gain_cents: -25_000, value_cents: 75_000})
    end

    test "a non-positive previous value is never flagged" do
      refute Returns.anomalous?(%{gain_cents: 50_000, value_cents: 50_000})
    end
  end

  describe "join_series/2 — the seam must not be a cliff" do
    defp realized(day, cents),
      do: %RealizedPoint{bucket_on: d(day), realized_cents: cents}

    defp recorded(day, cumulative),
      do: %{
        day: d(day),
        cumulative_cents: cumulative,
        gain_cents: 0,
        value_cents: 100_000,
        flow_cents: 0
      }

    test "with nothing recorded, every realized bucket survives" do
      out = Returns.join_series([realized("2026-01-01", 100), realized("2026-02-01", 200)], [])

      assert Enum.map(out, & &1.measure) == [:realized, :realized]
      assert Enum.map(out, & &1.cumulative_cents) == [100, 300]
    end

    test "realized buckets on or after the seam are dropped, not double-counted" do
      out =
        Returns.join_series(
          [realized("2026-01-01", 100), realized("2026-03-01", 999)],
          [recorded("2026-03-01", 0)]
        )

      assert Enum.map(out, & &1.measure) == [:realized, :recorded]
      refute Enum.any?(out, &(&1.measure == :realized and &1.cumulative_cents == 1_099))
    end

    test "the recorded segment is offset by the realized total so the line is continuous" do
      out =
        Returns.join_series(
          [realized("2026-01-01", 500)],
          [recorded("2026-02-01", 0), recorded("2026-02-02", 250)]
        )

      assert Enum.map(out, & &1.cumulative_cents) == [500, 500, 750]
    end

    test "with no realized history the recorded segment is unshifted" do
      out = Returns.join_series([], [recorded("2026-02-01", 0), recorded("2026-02-02", 250)])

      assert Enum.map(out, & &1.cumulative_cents) == [0, 250]
      assert Enum.all?(out, &(&1.measure == :recorded))
    end

    test "flow_cents is carried through so the chart can mark the day" do
      point = %{recorded("2026-02-01", 0) | flow_cents: 5_000}
      assert [out] = Returns.join_series([], [point])
      assert out.flow_cents == 5_000
    end

    test "realized points carry no value and no flow" do
      assert [out] = Returns.join_series([realized("2026-01-01", 100)], [])
      assert out.value_cents == nil
      assert out.flow_cents == 0
      assert out.gain_cents == 100
    end
  end
end
