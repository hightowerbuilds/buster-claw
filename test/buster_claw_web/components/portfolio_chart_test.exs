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

  describe "rebase/2 — the range control must mean something" do
    test "a window is re-zeroed against what it inherited" do
      series = [
        point("2026-01-01", -50_000),
        point("2026-06-01", -49_000),
        point("2026-06-20", -48_000)
      ]

      windowed = PortfolioChart.window(series, "1M")
      assert [a, b] = PortfolioChart.rebase(windowed, series)

      # Entering the window carrying -$500 of history, the past month is +$10.
      assert a.cumulative_cents == 0
      assert b.cumulative_cents == 1_000
    end

    test "the baseline is the point BEFORE the window, so the first visible change survives" do
      series = [point("2026-06-01", 1_000), point("2026-06-20", 3_000)]

      # "ALL" inherits nothing, so the opening point keeps its own change rather
      # than being flattened to zero.
      assert [a, b] = PortfolioChart.rebase(PortfolioChart.window(series, "ALL"), series)
      assert a.cumulative_cents == 1_000
      assert b.cumulative_cents == 3_000
    end

    test "the operator's own case: an old loss stops swamping a recent window" do
      # An account that lost $715 in early 2025 and has barely traded since.
      series = [
        point("2025-02-28", -71_581, :realized),
        point("2026-06-28", -49_841, :realized),
        point("2026-07-27", -49_841, :recorded)
      ]

      all = PortfolioChart.rebase(PortfolioChart.window(series, "ALL"), series)
      month = PortfolioChart.rebase(PortfolioChart.window(series, "1M"), series)

      # All-time still tells the truth about the loss...
      assert List.last(all).cumulative_cents == -49_841
      # ...but the past month reads as the flat stretch it actually was.
      assert List.last(month).cumulative_cents == 0
    end

    test "an empty window rebases to nothing rather than raising" do
      assert PortfolioChart.rebase([], [point("2026-01-01", 100)]) == []
    end
  end

  describe "range_counts/1 and flat?/1 — telling 'nothing to draw' from 'broken'" do
    test "counts what each range would plot, so a thin range can say so" do
      series = [
        point("2024-06-01", 100),
        point("2026-07-26", 200),
        point("2026-07-27", 300)
      ]

      counts = PortfolioChart.range_counts(series)

      # Two recent readings and one from two years ago.
      assert counts["1W"] == 2
      assert counts["ALL"] == 3
      # A range holding fewer than two points cannot draw a line at all.
      assert counts["3M"] == 2
    end

    test "a single-reading range is identified, not rendered as an empty axis" do
      series = [point("2024-06-01", 100), point("2026-07-27", 300)]
      counts = PortfolioChart.range_counts(series)

      assert counts["1W"] == 1
      assert counts["ALL"] == 2
    end

    test "flat? spots a window where nothing moved" do
      # The operator's own 1M case: two readings, identical cumulative. The line
      # lands exactly on the zero baseline and looks like a failed render.
      flat = [point("2026-06-28", 0, :realized), point("2026-07-27", 0)]
      assert PortfolioChart.flat?(flat)

      refute PortfolioChart.flat?([point("2026-07-26", 0), point("2026-07-27", 500)])
      refute PortfolioChart.flat?([])
    end

    test "a flat window still produces a drawable segment" do
      # It must be drawn AND described — the caption explains the line, it does
      # not replace it.
      flat = [point("2026-07-27", 0), point("2026-07-28", 0)]
      assert [_segment] = PortfolioChart.segments(flat)
    end
  end

  describe "default_range/1" do
    test "skips ranges with nothing to show and lands on the shortest with movement" do
      # The operator's own shape on 07-28: one recent reading, a flat month, and
      # real movement further back. Opening on 1M showed a flat line while two
      # years of history sat one click away.
      series = [
        point("2025-08-28", 0, :realized),
        point("2026-05-28", 50_000, :realized),
        point("2026-06-28", 51_386, :realized),
        point("2026-07-27", 51_386)
      ]

      assert PortfolioChart.default_range(series) == "3M"
    end

    test "prefers a short range once it has movement of its own" do
      series = [
        point("2024-01-01", 0, :realized),
        point("2026-07-26", 1_000),
        point("2026-07-27", 2_000)
      ]

      assert PortfolioChart.default_range(series) == "1W"
    end

    test "falls back to ALL when no range moves" do
      assert PortfolioChart.default_range([]) == "ALL"
      assert PortfolioChart.default_range([point("2026-07-27", 100)]) == "ALL"

      flat = [point("2026-07-26", 500), point("2026-07-27", 500)]
      assert PortfolioChart.default_range(flat) == "ALL"
    end

    test "the chosen range is always drawable" do
      series = [
        point("2024-01-01", 0, :realized),
        point("2026-01-28", -70_000, :realized),
        point("2026-07-27", -70_000)
      ]

      chosen = PortfolioChart.default_range(series)
      windowed = series |> PortfolioChart.window(chosen) |> PortfolioChart.rebase(series)

      assert match?([_, _ | _], windowed)
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

  describe "readout/1 — one sentence, three consumers" do
    test "each point carries coordinates and a formatted label" do
      series = [point("2026-07-27", 10_000), point("2026-07-28", 12_500)]

      assert [first, second] = Jason.decode!(PortfolioChart.readout(series))

      assert is_number(first["x"])
      assert is_number(first["y"])
      assert first["label"] =~ "2026-07-27"
      assert second["label"] =~ "+$125.00 cumulative"
    end

    test "a loss is signed, never left to color" do
      series = [point("2026-07-27", 0), point("2026-07-28", -4_200)]
      assert [_, loss] = Jason.decode!(PortfolioChart.readout(series))
      assert loss["label"] =~ "-$42.00"
    end

    test "a realized point says so — the reader must know what it excludes" do
      series = [
        point("2026-05-01", 100, :realized),
        point("2026-06-01", 200, :realized)
      ]

      assert [_, second] = Jason.decode!(PortfolioChart.readout(series))
      assert second["label"] =~ "realized trades only"
      assert second["label"] =~ "bucket"
    end

    test "a day carrying a transfer discloses it" do
      series = [
        point("2026-07-27", 0),
        Map.put(point("2026-07-28", 0), :flow_cents, 50_000)
      ]

      assert [_, marked] = Jason.decode!(PortfolioChart.readout(series))
      # The deposit was netted out of the gain, so the line shows nothing —
      # the label is the only place a reader can see it happened.
      assert marked["label"] =~ "includes a +$500.00 transfer"
    end

    test "an empty series is valid JSON, not a crash" do
      assert Jason.decode!(PortfolioChart.readout([])) == []
    end
  end

  describe "flow_marks/1" do
    test "marks only the days that actually carry a transfer" do
      series = [
        point("2026-07-27", 0),
        Map.put(point("2026-07-28", 0), :flow_cents, 50_000),
        point("2026-07-29", 0)
      ]

      assert [mark] = PortfolioChart.flow_marks(series)
      assert is_number(mark.x)
    end

    test "no transfers means no marks" do
      assert PortfolioChart.flow_marks([point("2026-07-27", 0)]) == []
      assert PortfolioChart.flow_marks([]) == []
    end
  end

  describe "symbol_geometry/2 and symbol_readout/2 — the price chart's rules" do
    defp bar(day, o, h, l, c) do
      %{
        bar_on: d(day),
        interval: "day",
        open_cents: o,
        high_cents: h,
        low_cents: l,
        close_cents: c,
        volume: 1_000
      }
    end

    defp close_only(day, c) do
      %{
        bar_on: d(day),
        interval: "day",
        open_cents: nil,
        high_cents: nil,
        low_cents: nil,
        close_cents: c,
        volume: nil
      }
    end

    test "zero is NOT forced into frame — the domain is padded min/max" do
      bars = [
        bar("2026-07-23", 32_000, 32_600, 31_800, 32_210),
        bar("2026-07-24", 32_200, 32_550, 31_900, 31_974)
      ]

      geometry = PortfolioChart.symbol_geometry(bars, :candles)

      # A $300 stock charted from $0 is unreadable; the gain chart's rule
      # deliberately inverts here.
      assert geometry.min_cents > 0
      assert geometry.min_cents < 31_800
      assert geometry.max_cents > 32_600
    end

    test "candles carry direction as class AND geometry, with a doji still visible" do
      bars = [
        bar("2026-07-22", 100, 120, 90, 110),
        bar("2026-07-23", 110, 115, 95, 100),
        bar("2026-07-24", 100, 105, 95, 100)
      ]

      geometry = PortfolioChart.symbol_geometry(bars, :candles)
      [up, down, doji] = geometry.candles

      assert up.class == "text-success"
      assert down.class == "text-error"
      # open == close still draws a sliver, not nothing.
      assert doji.body_h >= 1.0
      assert Enum.all?(geometry.candles, &(&1.wick_top <= &1.body_top))
    end

    test "line mode draws from closes alone — close-only rows are enough" do
      bars = [close_only("2026-07-23", 100), close_only("2026-07-24", 200)]

      geometry = PortfolioChart.symbol_geometry(bars, :line)
      assert geometry.candles == []
      assert length(String.split(geometry.line_points, " ")) == 2
    end

    test "the readout WRITES the OHLC — direction is never color alone" do
      bars = [
        bar("2026-07-23", 32_000, 32_600, 31_800, 32_210),
        bar("2026-07-24", 32_200, 32_550, 31_900, 31_974)
      ]

      [_, second] = Jason.decode!(PortfolioChart.symbol_readout(bars, :candles))

      assert second["label"] =~ "2026-07-24"
      assert second["label"] =~ "O $322.00"
      assert second["label"] =~ "H $325.50"
      assert second["label"] =~ "L $319.00"
      assert second["label"] =~ "C $319.74"
      assert second["label"] =~ "vol 1000"
    end

    test "a close-only row's readout admits it has only a close" do
      bars = [close_only("2026-07-23", 100), close_only("2026-07-24", 200)]
      [first, _] = Jason.decode!(PortfolioChart.symbol_readout(bars, :line))
      assert first["label"] =~ "close $1.00"
      refute first["label"] =~ "O $"
    end

    test "one bar draws nothing rather than a floating rectangle" do
      geometry = PortfolioChart.symbol_geometry([bar("2026-07-24", 100, 105, 95, 100)], :candles)
      assert geometry.candles == []
      assert PortfolioChart.symbol_readout([], :candles) == "[]"
    end
  end

  describe "spark_points/1" do
    test "fewer than two closes is nil — a dot is not a trend" do
      assert PortfolioChart.spark_points([]) == nil
      assert PortfolioChart.spark_points([100]) == nil
    end

    test "a flat series stays in bounds without dividing by zero" do
      points = PortfolioChart.spark_points([500, 500, 500])
      assert is_binary(points)

      for pair <- String.split(points, " "),
          [x, y] = String.split(pair, ",") do
        assert String.to_float(x) >= 0.0
        assert String.to_float(y) >= 0.0
      end
    end

    test "points span the full width, oldest left" do
      points = PortfolioChart.spark_points([100, 200, 300])
      pairs = String.split(points, " ")

      assert length(pairs) == 3
      assert hd(pairs) |> String.starts_with?("0.0,")
      assert List.last(pairs) |> String.starts_with?("72.0,")
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
