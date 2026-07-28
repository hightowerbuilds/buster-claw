defmodule BusterClawWeb.PortfolioChartTest do
  use ExUnit.Case, async: true

  alias BusterClawWeb.PortfolioChart

  defp d(iso), do: Date.from_iso8601!(iso)

  defp point(day, cents, measure \\ :recorded) do
    %{day: d(day), cumulative_cents: cents, measure: measure, gain_cents: 0, value_cents: 1_000}
  end

  describe "window/2" do
    test "counts back from the last point, not from today" do
      # A stale series must still show its own last month rather than an empty
      # window because the calendar moved on.
      series = [
        point("2026-01-01", 100),
        point("2026-06-01", 200),
        point("2026-06-20", 300)
      ]

      assert [a, b] = PortfolioChart.window(series, "1M")
      assert a.day == d("2026-06-01")
      assert b.day == d("2026-06-20")
    end

    test "ALL keeps everything and an unknown range is not destructive" do
      series = [point("2024-01-01", 1), point("2026-06-20", 2)]
      assert PortfolioChart.window(series, "ALL") == series
      assert PortfolioChart.window(series, "nonsense") == series
    end

    test "an empty series survives every range" do
      for range <- ["1W", "1M", "3M", "1Y", "ALL"] do
        assert PortfolioChart.window([], range) == []
      end
    end
  end

  describe "granularity/1" do
    test "is chosen from the span, not the point count" do
      assert PortfolioChart.granularity([]) == :daily
      assert PortfolioChart.granularity([point("2026-01-01", 1)]) == :daily

      assert PortfolioChart.granularity([point("2026-01-01", 1), point("2026-02-01", 2)]) ==
               :daily

      assert PortfolioChart.granularity([point("2026-01-01", 1), point("2026-06-01", 2)]) ==
               :weekly

      assert PortfolioChart.granularity([point("2024-01-01", 1), point("2026-06-01", 2)]) ==
               :monthly
    end
  end

  describe "downsample/1" do
    test "keeps the LAST point in each period — a level, never an average" do
      series =
        for day <- Date.range(d("2026-01-01"), d("2026-12-31")) do
          %{
            day: day,
            cumulative_cents: Date.day_of_year(day),
            measure: :recorded,
            gain_cents: 0,
            value_cents: 0
          }
        end

      plotted = PortfolioChart.downsample(series)

      # A 364-day span is weekly (monthly starts past 400 days). What matters is
      # that every retained value is one that really occurred on that day — an
      # average of levels would be a number that never existed.
      assert PortfolioChart.granularity(series) == :weekly
      assert length(plotted) < length(series)

      assert Enum.all?(plotted, fn p -> p.cumulative_cents == Date.day_of_year(p.day) end)
      assert List.last(plotted).day == d("2026-12-31")
    end

    test "measures are downsampled separately so the seam stays crisp" do
      series = [
        point("2024-01-15", 100, :realized),
        point("2024-01-20", 200, :realized),
        # Same month, different measure — must not collapse into the realized one.
        point("2024-01-25", 300, :recorded),
        point("2026-06-01", 400, :recorded)
      ]

      plotted = PortfolioChart.downsample(series)
      measures = Enum.map(plotted, & &1.measure)

      assert :realized in measures
      assert :recorded in measures
    end

    test "daily spans are returned untouched" do
      series = [point("2026-06-01", 1), point("2026-06-05", 2)]
      assert PortfolioChart.downsample(series) == series
    end
  end

  describe "gap?/2 — the rule that stops the line lying" do
    test "consecutive trading days are continuous" do
      # Monday to Tuesday.
      refute PortfolioChart.gap?(d("2026-07-27"), d("2026-07-28"))
    end

    test "a weekend is not a gap — the market was shut, not unmeasured" do
      # Friday to Monday.
      refute PortfolioChart.gap?(d("2026-07-24"), d("2026-07-27"))
    end

    test "a market holiday between readings is not a gap" do
      # 2026-07-03 is the observed Independence Day; Thursday to Monday.
      refute PortfolioChart.gap?(d("2026-07-02"), d("2026-07-06"))
    end

    test "a missed trading day IS a gap" do
      # Monday to Wednesday, with Tuesday unmeasured.
      assert PortfolioChart.gap?(d("2026-07-27"), d("2026-07-29"))
    end
  end

  describe "segments/1" do
    test "a gap breaks the line rather than spanning it" do
      series = [
        point("2026-07-27", 100),
        # Tuesday missing.
        point("2026-07-29", 200),
        point("2026-07-30", 300)
      ]

      # One drawable segment: the lone point before the gap has nothing to
      # connect to and is dropped rather than reaching across the hole.
      assert [only] = PortfolioChart.segments(series)
      assert only.measure == :recorded
      # Two coordinates, not three — the 27th is not in this path.
      assert length(String.split(only.d, " L ")) == 2
    end

    test "a gap between two real stretches yields two separate paths" do
      series = [
        point("2026-07-23", 50),
        point("2026-07-24", 100),
        # The 27th and 28th are unmeasured trading days.
        point("2026-07-29", 200),
        point("2026-07-30", 300)
      ]

      assert [first, second] = PortfolioChart.segments(series)
      assert first.measure == :recorded
      assert second.measure == :recorded
      assert String.starts_with?(second.d, "M ")
    end

    test "a change of measure starts a new path that still CONNECTS at the seam" do
      series = [
        point("2026-05-01", 100, :realized),
        point("2026-06-01", 200, :realized),
        point("2026-07-27", 200, :recorded),
        point("2026-07-28", 250, :recorded)
      ]

      assert [realized, recorded] = PortfolioChart.segments(series)
      assert realized.measure == :realized
      assert recorded.measure == :recorded

      # The recorded path repeats the last realized point, so the line is
      # unbroken and only its style changes. Three coordinates, not two.
      assert length(String.split(recorded.d, " L ")) == 3
    end

    test "a window holding only the seam still draws a line" do
      # The 07-28 bug: one realized point and one recorded point produced two
      # single-point chunks, both dropped, and the chart rendered no line at all
      # while claiming the series was continuous.
      series = [
        point("2026-06-28", 21_740, :realized),
        point("2026-07-27", 21_740, :recorded)
      ]

      assert [only] = PortfolioChart.segments(series)
      assert only.measure == :recorded
      assert length(String.split(only.d, " L ")) == 2
    end

    test "a gap is still a hard break — no connecting stroke across it" do
      series = [
        point("2026-07-23", 50),
        point("2026-07-24", 100),
        point("2026-07-29", 200),
        point("2026-07-30", 300)
      ]

      assert [first, second] = PortfolioChart.segments(series)
      # Two coordinates each: neither path borrows a point from the other side.
      assert length(String.split(first.d, " L ")) == 2
      assert length(String.split(second.d, " L ")) == 2
    end

    test "monthly realized buckets are never treated as gaps" do
      series = [
        point("2026-01-28", 100, :realized),
        point("2026-02-28", 200, :realized),
        point("2026-03-28", 300, :realized)
      ]

      assert [only] = PortfolioChart.segments(series)
      assert only.measure == :realized
    end

    test "fewer than two points draw nothing" do
      assert PortfolioChart.segments([]) == []
      assert PortfolioChart.segments([point("2026-07-27", 100)]) == []
    end

    test "paths start with M and continue with L" do
      series = [point("2026-07-27", 100), point("2026-07-28", 200)]
      assert [%{d: d}] = PortfolioChart.segments(series)
      assert String.starts_with?(d, "M ")
      assert d =~ " L "
    end
  end

  describe "geometry/1" do
    test "zero is always inside the domain, even for an all-positive series" do
      series = [point("2026-07-27", 5_000), point("2026-07-28", 9_000)]
      geometry = PortfolioChart.geometry(series)

      assert geometry.min_cents == 0
      assert geometry.max_cents == 9_000
    end

    test "zero is inside the domain for an all-negative series too" do
      series = [point("2026-07-27", -5_000), point("2026-07-28", -9_000)]
      geometry = PortfolioChart.geometry(series)

      assert geometry.min_cents == -9_000
      assert geometry.max_cents == 0
    end

    test "a flat series does not divide by zero" do
      series = [point("2026-07-27", 0), point("2026-07-28", 0)]
      geometry = PortfolioChart.geometry(series)

      assert is_number(geometry.zero_y)
      assert Enum.all?(geometry.dots, &is_number(&1.y))
    end

    test "a single point is placed without dividing by a zero span" do
      geometry = PortfolioChart.geometry([point("2026-07-27", 100)])
      assert [dot] = geometry.dots
      assert is_number(dot.x)
      assert is_number(dot.y)
    end

    test "dots are dropped once they stop being individually legible" do
      series =
        for day <- Date.range(d("2025-01-01"), d("2026-06-01")) do
          %{
            day: day,
            cumulative_cents: 100,
            measure: :recorded,
            gain_cents: 0,
            value_cents: 0
          }
        end

      assert PortfolioChart.geometry(series).dots == []
    end

    test "an empty series yields empty geometry rather than raising" do
      geometry = PortfolioChart.geometry([])
      assert geometry.dots == []
      assert is_number(geometry.zero_y)
    end
  end
end
