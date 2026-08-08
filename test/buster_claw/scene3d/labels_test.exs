defmodule BusterClaw.Scene3d.LabelsTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Scene3d.Labels

  # The viewbox `Project` emits for a scene centred on the origin.
  @viewbox {-100.0, -100.0, 200.0, 200.0}

  @base_fraction 0.055
  @min_fraction 0.018

  # The motivating screenshot: thirteen names of things within a few miles of
  # each other, which is what a map of anywhere real looks like.
  @puget [
    "Deception Pass Bridge",
    "Fidalgo Island",
    "Oak Harbor",
    "Whidbey Island",
    "Camano Island",
    "Port Townsend",
    "Admiralty Inlet",
    "Skagit Bay",
    "Saratoga Passage",
    "Possession Sound",
    "Everett",
    "Mukilteo",
    "Hat Island"
  ]

  # ── Fixtures ────────────────────────────────────────────────────────────────

  defp label(x, y, text, depth), do: %{at: {x, y}, text: text, depth: depth}

  # Names crowded into a small patch near the middle of the card. Positions are
  # index-derived rather than random so the fixture is reproducible.
  defp clustered(texts, spread) do
    texts
    |> Enum.with_index()
    |> Enum.map(fn {text, i} ->
      x = -spread / 2.0 + rem(i * 7, 30) * spread / 30.0
      y = -spread / 2.0 + rem(i * 11, 30) * spread / 30.0

      label(x, y, text, i * 1.0)
    end)
  end

  # `count` labels spread evenly over the card, so nothing is fighting for room
  # and the only thing under test is the size curve.
  defp spread(count, text \\ "N") do
    for i <- 0..(count - 1) do
      label(-80.0 + rem(i, 8) * 20.0, -80.0 + div(i, 8) * 20.0, "#{text}#{i}", i * 1.0)
    end
  end

  # ── Assertions ──────────────────────────────────────────────────────────────

  defp overlapping?({ax1, ay1, ax2, ay2}, {bx1, by1, bx2, by2}) do
    ax1 < bx2 and bx1 < ax2 and ay1 < by2 and by1 < ay2
  end

  # THE property. Everything else in this file is a detail of how it is achieved.
  defp assert_no_overlap(placed, opts \\ []) do
    indexed = placed |> Enum.map(&Labels.box(&1, opts)) |> Enum.with_index()

    for {a, i} <- indexed, {b, j} <- indexed, i < j do
      refute overlapping?(a, b),
             "labels #{i} (#{Enum.at(placed, i).text}) and #{j} (#{Enum.at(placed, j).text}) " <>
               "overlap: #{inspect(a)} vs #{inspect(b)}"
    end

    placed
  end

  defp assert_inside(placed, {min_x, min_y, width, height} = viewbox) do
    for label <- placed do
      {x1, y1, x2, y2} = Labels.box(label)

      assert x1 >= min_x and x2 <= min_x + width,
             "#{label.text} escapes #{inspect(viewbox)} horizontally: #{inspect({x1, x2})}"

      assert y1 >= min_y and y2 <= min_y + height,
             "#{label.text} escapes #{inspect(viewbox)} vertically: #{inspect({y1, y2})}"
    end

    placed
  end

  # ── The headline property ───────────────────────────────────────────────────

  describe "no two placed labels overlap" do
    test "a handful of well-separated labels" do
      [label(-60.0, -60.0, "North Yard", 3.0), label(60.0, 60.0, "South Yard", 1.0)]
      |> Labels.layout(@viewbox)
      |> assert_no_overlap()
      |> assert_inside(@viewbox)
    end

    test "the thirteen Puget Sound labels that started this" do
      placed =
        @puget
        |> clustered(30.0)
        |> Labels.layout(@viewbox)
        |> assert_no_overlap()
        |> assert_inside(@viewbox)

      assert placed != []
    end

    test "the same thirteen crammed into a tenth of the space" do
      @puget
      |> clustered(3.0)
      |> Labels.layout(@viewbox)
      |> assert_no_overlap()
      |> assert_inside(@viewbox)
    end

    test "fifteen labels at very nearly the same point" do
      placed =
        for i <- 0..14 do
          label(0.1 * i, 0.1 * i, "Marker #{i}", i * 1.0)
        end
        |> Labels.layout(@viewbox)
        |> assert_no_overlap()
        |> assert_inside(@viewbox)

      assert placed != [], "a pile of labels should still yield a readable few"
    end

    test "thirty labels at exactly the same point with identical text" do
      for i <- 0..29 do
        label(0.0, 0.0, "Node", i * 1.0)
      end
      |> Labels.layout(@viewbox)
      |> assert_no_overlap()
      |> assert_inside(@viewbox)
    end

    test "a dense grid whose spacing is smaller than the text" do
      for i <- 0..24 do
        label(-20.0 + rem(i, 5) * 10.0, -20.0 + div(i, 5) * 10.0, "Terminal #{i}", i * 1.0)
      end
      |> Labels.layout(@viewbox)
      |> assert_no_overlap()
      |> assert_inside(@viewbox)
    end

    test "labels anchored outside the frame are pulled in or dropped, never left out" do
      for {x, y} <- [{-400.0, 0.0}, {400.0, 0.0}, {0.0, -400.0}, {0.0, 400.0}] do
        label(x, y, "Offstage", 1.0)
      end
      |> Labels.layout(@viewbox)
      |> assert_no_overlap()
      |> assert_inside(@viewbox)
    end
  end

  # ── Dropping ────────────────────────────────────────────────────────────────

  describe "dropping is the trade, not a failure" do
    test "more labels than there are positions means fewer labels come back" do
      labels = for i <- 0..29, do: label(0.0, 0.0, "Node", i * 1.0)

      placed = Labels.layout(labels, @viewbox)

      # Identical text at an identical anchor gives every label the identical
      # candidate set, and there are fewer candidates than labels, so some of
      # them cannot be placed no matter how the search is tuned.
      assert length(placed) < length(labels)
      assert placed != []

      assert_no_overlap(placed)
      assert_inside(placed, @viewbox)
    end

    test "the survivors are the ones nearest the camera" do
      # Same anchor and same *width* for every label, so every label is offered
      # exactly the same candidate positions and the only thing separating them
      # is priority. The ones that get dropped are then provably the far ones.
      labels =
        for i <- 0..29 do
          label(0.0, 0.0, "Node #{String.pad_leading(Integer.to_string(i), 2, "0")}", i * 1.0)
        end

      placed = Labels.layout(labels, @viewbox)

      assert length(placed) < length(labels)

      assert Enum.map(placed, & &1.text) ==
               labels |> Enum.map(& &1.text) |> Enum.take(length(placed))
    end

    test "a label wider than the whole frame is dropped rather than clipped" do
      wide = label(0.0, 0.0, String.duplicate("wide ", 200), 1.0)

      assert Labels.layout([wide], @viewbox) == []
    end

    test "a crowd of long names loses some but keeps the near ones" do
      labels =
        for i <- 0..19 do
          label(0.05 * i, 0.05 * i, "Deception Pass Bridge #{i}", i * 1.0)
        end

      placed = Labels.layout(labels, @viewbox)

      assert length(placed) < length(labels)
      assert hd(placed).text == "Deception Pass Bridge 0"

      assert_no_overlap(placed)
    end
  end

  # ── Leaders ─────────────────────────────────────────────────────────────────

  describe "leader lines" do
    test "a label that lands on its anchor needs no leader" do
      assert [placed] = Labels.layout([label(0.0, 0.0, "Hub", 1.0)], @viewbox)

      assert placed.at == {0.0, 0.0}
      assert placed.anchor == {0.0, 0.0}
      refute placed.leader
    end

    test "a label pushed off its anchor gets one, and keeps the anchor it names" do
      labels = [label(0.0, 0.0, "First", 1.0), label(0.0, 0.0, "Second", 2.0)]

      assert [first, second] = Labels.layout(labels, @viewbox)

      refute first.leader
      assert first.at == {0.0, 0.0}

      assert second.leader
      assert second.at != {0.0, 0.0}
      # The anchor is still the point it names — that is what the leader draws to.
      assert second.anchor == {0.0, 0.0}

      assert_no_overlap([first, second])
    end

    test "a label clamped in from the edge of the frame gets one" do
      assert [placed] = Labels.layout([label(-100.0, -100.0, "Corner", 1.0)], @viewbox)

      assert placed.leader
      assert placed.anchor == {-100.0, -100.0}
      assert_inside([placed], @viewbox)
    end
  end

  # ── Size ────────────────────────────────────────────────────────────────────

  describe "font size falls off with label count" do
    defp size_for(count) do
      assert [placed | _] = Labels.layout(spread(count), @viewbox)

      placed.size
    end

    test "one label gets the full size" do
      assert_in_delta size_for(1), @base_fraction * 200.0, 1.0e-9
    end

    test "size decreases strictly as labels are added" do
      sizes = Enum.map([1, 3, 8, 20], &size_for/1)

      assert sizes == Enum.sort(sizes, :desc)
      assert Enum.uniq(sizes) == sizes

      # Concretely: thirteen labels are drawn at well under half the size one
      # label would get. That is the whole point of the curve.
      assert size_for(13) < size_for(1) / 2.0
    end

    test "size never falls below the floor, however many labels arrive" do
      floor = @min_fraction * 200.0

      for count <- [40, 64, 120] do
        assert_in_delta size_for(count), floor, 1.0e-9
      end

      for count <- [1, 3, 13, 40, 120] do
        assert size_for(count) >= floor
      end
    end

    test "every label in a layout is the same size" do
      placed = Labels.layout(clustered(@puget, 30.0), @viewbox)

      assert placed != []
      assert placed |> Enum.map(& &1.size) |> Enum.uniq() |> length() == 1
    end

    test "size scales with the frame, not with scene units" do
      big = Labels.layout([label(0.0, 0.0, "Hub", 1.0)], {-1000.0, -1000.0, 2000.0, 2000.0})
      small = Labels.layout([label(0.0, 0.0, "Hub", 1.0)], @viewbox)

      assert_in_delta hd(big).size / hd(small).size, 10.0, 1.0e-9
    end

    test "a non-square frame sizes from its short side" do
      wide = Labels.layout([label(0.0, 0.0, "Hub", 1.0)], {-150.0, -50.0, 300.0, 100.0})

      assert_in_delta hd(wide).size, @base_fraction * 100.0, 1.0e-9
    end
  end

  # ── Options ─────────────────────────────────────────────────────────────────

  describe "options" do
    test "falloff can be switched off" do
      placed = Labels.layout(spread(20), @viewbox, falloff: 0.0)

      assert_in_delta hd(placed).size, @base_fraction * 200.0, 1.0e-9
    end

    test "a wider em scale makes boxes wider, so fewer labels fit" do
      labels = clustered(@puget, 4.0)

      narrow = Labels.layout(labels, @viewbox, em_scale: 0.6)
      wide = Labels.layout(labels, @viewbox, em_scale: 2.5)

      assert length(narrow) == length(labels)
      assert length(wide) < length(narrow)

      # Measured with the same em scale they were placed with, the survivors are
      # still disjoint — which is the honest statement of the guarantee: it holds
      # for whatever text extent you told this module to assume.
      assert_no_overlap(wide, em_scale: 2.5)
    end

    test "box/2 honours the same em scale layout was given" do
      [placed] = Labels.layout([label(0.0, 0.0, "Hub", 1.0)], @viewbox, em_scale: 2.0)

      {x1, _y1, x2, _y2} = Labels.box(placed, em_scale: 2.0)
      {n1, _, n2, _} = Labels.box(placed)

      assert_in_delta x2 - x1, 2.0 * (n2 - n1), 1.0e-9
    end
  end

  # ── Totality and determinism ────────────────────────────────────────────────

  describe "totality" do
    test "empty input returns empty" do
      assert Labels.layout([], @viewbox) == []
      assert Labels.layout([], @viewbox, size_fraction: 0.2) == []
    end

    test "a degenerate viewbox holds nothing rather than raising" do
      assert Labels.layout([label(0.0, 0.0, "Hub", 1.0)], {0.0, 0.0, 0.0, 0.0}) == []
    end

    test "an off-centre viewbox is respected" do
      viewbox = {50.0, -20.0, 200.0, 200.0}

      for i <- 0..9 do
        label(150.0 + i * 1.0, 80.0 + i * 1.0, "Berth #{i}", i * 1.0)
      end
      |> Labels.layout(viewbox)
      |> assert_no_overlap()
      |> assert_inside(viewbox)
    end

    test "blank text is skipped rather than given a slot" do
      labels = [
        label(0.0, 0.0, "", 1.0),
        label(0.0, 0.0, "   ", 2.0),
        label(0.0, 0.0, "Hub", 3.0)
      ]

      # A zero-width box collides with nothing and would happily take the anchor,
      # spending the best position in the layout to draw nothing at all.
      assert [placed] = Labels.layout(labels, @viewbox)
      assert placed.text == "Hub"
      refute placed.leader
    end

    test "a structurally malformed label is skipped, not raised on" do
      junk = [
        %{at: {0.0, 0.0}, text: nil, depth: 1.0},
        %{at: {0.0, 0.0}, text: 42, depth: 1.0},
        %{at: {0.0, 0.0}, text: :atom, depth: 1.0},
        %{at: {0.0, 0.0}, text: ~c"charlist", depth: 1.0},
        %{at: nil, text: "no anchor", depth: 1.0},
        %{at: {0.0}, text: "short anchor", depth: 1.0},
        %{at: {"x", "y"}, text: "string anchor", depth: 1.0},
        %{at: {0.0, 0.0}, text: "no depth", depth: nil},
        %{at: {0.0, 0.0}, text: "missing keys"},
        %{},
        "not a label at all"
      ]

      # `validate/1` makes this unreachable through the pipeline. It is asserted
      # anyway: this is the last stage before markup reaches a live view, and a
      # raise here is a crashed LiveView.
      assert Labels.layout(junk, @viewbox) == []
    end

    test "good labels survive alongside junk, and are sized as if the junk were absent" do
      good = for i <- 0..2, do: label(-50.0 + i * 50.0, 0.0, "Real #{i}", i * 1.0)
      junk = for i <- 0..9, do: %{at: {0.0, 0.0}, text: nil, depth: i * 1.0}

      placed = Labels.layout(good ++ junk, @viewbox)

      assert Enum.map(placed, & &1.text) == ["Real 0", "Real 1", "Real 2"]
      # Sized for three labels, not thirteen.
      assert_in_delta hd(placed).size, hd(Labels.layout(good, @viewbox)).size, 1.0e-9
    end

    test "every result carries exactly the keys the contract declares" do
      for placed <- Labels.layout(clustered(@puget, 20.0), @viewbox) do
        assert placed |> Map.keys() |> Enum.sort() == [:anchor, :at, :leader, :size, :text]
        assert is_boolean(placed.leader)
        assert is_float(placed.size)
        assert {_, _} = placed.at
        assert {_, _} = placed.anchor
      end
    end
  end

  describe "determinism" do
    test "the same input produces the same output, every time" do
      labels = clustered(@puget, 6.0)

      first = Labels.layout(labels, @viewbox)

      for _ <- 1..5 do
        assert Labels.layout(labels, @viewbox) == first
      end
    end

    test "ties in depth are broken by input order, not by anything ambient" do
      a = label(0.0, 0.0, "Alpha", 1.0)
      b = label(0.0, 0.0, "Beta", 1.0)

      assert [first, second] = Labels.layout([a, b], @viewbox)
      assert first.text == "Alpha"
      refute first.leader
      assert second.leader

      assert [flipped | _] = Labels.layout([b, a], @viewbox)
      assert flipped.text == "Beta"
    end

    test "results come back nearest-camera-first regardless of input order" do
      near = label(-50.0, -50.0, "Near", 1.0)
      middle = label(0.0, 0.0, "Middle", 5.0)
      far = label(50.0, 50.0, "Far", 9.0)

      assert Enum.map(Labels.layout([far, near, middle], @viewbox), & &1.text) ==
               ["Near", "Middle", "Far"]
    end
  end
end
