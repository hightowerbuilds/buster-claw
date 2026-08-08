defmodule BusterClaw.Scene3d.SvgTest do
  # Pure function under test: no repo, no processes, no sandbox.
  use ExUnit.Case, async: true

  alias BusterClaw.Scene3d.Svg

  # The frame contract (`BusterClaw.Scene3d.Types`) is the input; these helpers
  # build one so a test says only what it is actually about.
  defp frame(overrides \\ %{}) do
    Map.merge(
      %{polys: [], lines: [], labels: [], viewbox: {0.0, 0.0, 100.0, 60.0}},
      Map.new(overrides)
    )
  end

  defp poly(points, color, shade \\ 1.0, role \\ :solid) do
    %{points: points, color: color, shade: shade, depth: 0.0, role: role}
  end

  defp line(a, b, color, width \\ 2.0, depth \\ 0.0) do
    %{a: a, b: b, color: color, width: width, depth: depth}
  end

  defp label(at, text, depth \\ 0.0), do: %{at: at, text: text, depth: depth}

  # A `t:Types.placed_label/0` — what `Scene3d.Labels` hands back. Tests that are
  # about *rendering* a placed label inject these through the `:layout` seam, so
  # they assert on this module and not on another module's collision policy.
  defp placed(at, text, size, opts \\ []) do
    %{
      at: at,
      anchor: Keyword.get(opts, :anchor, at),
      text: text,
      size: size,
      leader: Keyword.get(opts, :leader, false)
    }
  end

  defp layout(placed_labels), do: [layout: fn _labels, _viewbox, _opts -> placed_labels end]

  defp square(offset) do
    [{offset, offset}, {offset + 10, offset}, {offset + 10, offset + 10}, {offset, offset + 10}]
  end

  # All `fill="#rrggbb"` values in document order.
  defp fills(svg), do: ~r/fill="(#[0-9a-f]{6})"/ |> Regex.scan(svg) |> Enum.map(&List.last/1)

  defp fill(svg), do: svg |> fills() |> List.first()

  # Distance between the largest and smallest RGB channel: a crude but adequate
  # stand-in for chroma, and the thing a "muted" tone must have much less of.
  defp spread("#" <> hex) do
    channels = for <<pair::binary-2 <- hex>>, do: String.to_integer(pair, 16)
    Enum.max(channels) - Enum.min(channels)
  end

  # Well-formedness, proved by a real XML parser rather than a regex. `xmerl` is
  # in OTP, so this costs no dep; `bin_to_list/1` hands it UTF-8 *bytes* (a
  # charlist of codepoints would break on any non-ASCII label).
  defp parse!(svg) do
    {doc, rest} = :xmerl_scan.string(:binary.bin_to_list(svg), quiet: true)
    assert rest == [], "trailing bytes after the document: #{inspect(rest)}"
    doc
  end

  # Byte offset of a substring, for order assertions.
  defp at(svg, needle) do
    case :binary.match(svg, needle) do
      {pos, _len} -> pos
      :nomatch -> flunk("expected to find #{inspect(needle)} in:\n#{svg}")
    end
  end

  describe "document shape" do
    test "a populated frame parses as well-formed XML" do
      svg =
        Svg.render(
          frame(%{
            polys: [poly(square(0), 0), poly(square(20), 1, 0.5)],
            lines: [line({0.0, 0.0}, {50.0, 50.0}, 2)],
            labels: [label({25.0, 25.0}, "core")]
          })
        )

      parse!(svg)
    end

    test "the viewBox comes from the frame and no width/height is emitted" do
      svg = Svg.render(frame(%{viewbox: {-12.5, -8.0, 120.0, 90.0}}))

      assert svg =~ ~s(viewBox="-12.5 -8 120 90")
      # The card sizes it with CSS; a hardcoded size would fight that.
      refute svg =~ ~s( width=")
      refute svg =~ ~s( height=")
    end

    test "opts supply the CSS class and the accessible name" do
      svg = Svg.render(frame(), class: "w-full h-64", title: "Rack layout")

      assert svg =~ ~s(class="w-full h-64")
      assert svg =~ "<title>Rack layout</title>"
      assert svg =~ ~s(role="img")
      parse!(svg)
    end

    test "without a title the accessible name is derived from the scene's labels" do
      svg = Svg.render(frame(%{labels: [label({0.0, 0.0}, "web"), label({1.0, 1.0}, "db")]}))

      # role="img" hides the inner <text> from assistive tech, so the labels have
      # to reach the name somehow or the scene says nothing out loud.
      assert svg =~ "<title>3D scene: web, db</title>"
    end
  end

  describe "emission order" do
    test "polys are emitted in the order given — this stage never sorts" do
      svg =
        Svg.render(
          frame(%{polys: [poly(square(0), 0), poly(square(20), 0), poly(square(40), 0)]})
        )

      assert at(svg, "0,0") < at(svg, "20,20")
      assert at(svg, "20,20") < at(svg, "40,40")
    end

    test "lines are emitted in the order given" do
      svg =
        Svg.render(
          frame(%{
            lines: [
              line({1.0, 1.0}, {2.0, 2.0}, 0),
              line({3.0, 3.0}, {4.0, 4.0}, 0),
              line({5.0, 5.0}, {6.0, 6.0}, 0)
            ]
          })
        )

      assert at(svg, ~s(x1="1")) < at(svg, ~s(x1="3"))
      assert at(svg, ~s(x1="3")) < at(svg, ~s(x1="5"))
    end

    test "labels are emitted in order and after ALL geometry, so nothing occludes them" do
      svg =
        Svg.render(
          frame(%{
            # Interleaved on input: a label first, geometry after. Output must
            # still put every label last (roadmap decision 5).
            labels: [label({5.0, 5.0}, "alpha"), label({6.0, 6.0}, "beta")],
            polys: [poly(square(0), 0)],
            lines: [line({0.0, 0.0}, {9.0, 9.0}, 1)]
          })
        )

      assert at(svg, "<polygon") < at(svg, "<line")
      assert at(svg, "<line") < at(svg, "<text")
      assert at(svg, "alpha") < at(svg, "beta")
    end
  end

  describe "label text is the only injection surface, and it is escaped" do
    test "a <script> label comes out inert" do
      hostile = "<script>alert(1)</script>"
      svg = Svg.render(frame(%{labels: [label({0.0, 0.0}, hostile)]}))

      refute svg =~ "<script"
      refute svg =~ "</script>"
      assert svg =~ "&lt;script&gt;alert(1)&lt;/script&gt;"

      # And it survives as *text*: parsing gives the original string back, which
      # is what "escaped, not stripped" means.
      assert texts(parse!(svg)) == ["3D scene: #{hostile}", hostile]
    end

    test "an attribute-breaking label comes out inert" do
      hostile = ~s(" onload="x)
      svg = Svg.render(frame(%{labels: [label({0.0, 0.0}, hostile)]}))

      # The quotes are escaped, so nothing can close an attribute and start a
      # handler. `onload=` may appear as literal text; `onload="` must not.
      refute svg =~ ~s(onload="x)
      assert svg =~ "&quot;"
      assert texts(parse!(svg)) == ["3D scene: #{hostile}", hostile]
    end

    test "hostile text in the title and class opts is escaped too" do
      svg =
        Svg.render(frame(),
          title: "<script>alert(1)</script>",
          class: ~s(a" onload="x)
        )

      refute svg =~ "<script"
      refute svg =~ ~s(onload="x)
      parse!(svg)
    end

    test "a non-binary label cannot crash the renderer" do
      svg = Svg.render(frame(%{labels: [label({0.0, 0.0}, nil)]}))

      # Whether a junk label gets *placed* is `Scene3d.Labels`' call. That it can
      # never crash this stage or leak an inspected term into the DOM is ours.
      parse!(svg)
      refute svg =~ "nil"
    end

    test "a malformed placed label is dropped rather than crashing the last stage" do
      svg =
        Svg.render(
          frame(%{labels: [label({0.0, 0.0}, "ok")]}),
          layout([%{text: "no at, no anchor"}])
        )

      refute svg =~ "<text"
      parse!(svg)
    end
  end

  describe "palette" do
    test "the five slots map to five distinct colours" do
      fills =
        for index <- 0..4 do
          svg = Svg.render(frame(%{polys: [poly(square(0), index)]}))
          [_, fill] = Regex.run(~r/fill="(#[0-9a-f]{6})"/, svg)
          fill
        end

      assert length(Enum.uniq(fills)) == 5
      # Pinned: the order is the colourblind-safety mechanism, not decoration.
      assert fills == ["#ff4407", "#00a1ce", "#9417ff", "#e10095", "#ac9000"]
    end

    test "an out-of-range or nonsense index falls back instead of crashing" do
      for bad <- [5, -1, 99, nil, :orange, "0"] do
        svg = Svg.render(frame(%{polys: [poly(square(0), bad)]}))

        assert svg =~ ~s(fill="#ff4407")
        parse!(svg)
      end
    end

    test "lines resolve through the same palette" do
      svg = Svg.render(frame(%{lines: [line({0.0, 0.0}, {1.0, 1.0}, 3)]}))

      assert svg =~ ~s(stroke="#e10095")
    end
  end

  describe "shading and strokes" do
    test "shade darkens the palette colour, and does so subtly" do
      lit = Svg.render(frame(%{polys: [poly(square(0), 1, 1.0)]}))
      dim = Svg.render(frame(%{polys: [poly(square(0), 1, 0.0)]}))

      [_, lit_fill] = Regex.run(~r/fill="(#[0-9a-f]{6})"/, lit)
      [_, dim_fill] = Regex.run(~r/fill="(#[0-9a-f]{6})"/, dim)

      assert lit_fill == "#00a1ce"
      assert dim_fill != lit_fill
      # Subtle on purpose (Phase 1): a wide range sinks facets into the #121212
      # ground. Real shading is Phase 2.
      assert dim_fill == "#0081a5"
    end

    test "a shade outside 0.0..1.0 is clamped rather than producing a bad colour" do
      for shade <- [-5.0, 12.0, nil] do
        svg = Svg.render(frame(%{polys: [poly(square(0), 0, shade)]}))

        assert [_, fill] = Regex.run(~r/fill="(#[0-9a-f]{6})"/, svg)
        assert String.length(fill) == 7
      end
    end

    test "faces carry an edge stroke so silhouettes read" do
      svg = Svg.render(frame(%{polys: [poly(square(0), 0, 1.0)]}))

      # Derived from the *unshaded* colour, so the seam is continuous across
      # facets of differing brightness.
      assert svg =~ ~s(stroke="#8c2504")
      assert svg =~ ~s(vector-effect="non-scaling-stroke")
    end
  end

  describe "role: :surface is a backdrop, not a series colour" do
    test "the same palette slot renders differently as a surface than as a solid" do
      solid = Svg.render(frame(%{polys: [poly(square(0), 3, 1.0, :solid)]}))
      surface = Svg.render(frame(%{polys: [poly(square(0), 3, 1.0, :surface)]}))

      # The motivating bug in one assertion: a water plane authored in slot 3 was
      # coming out as the same saturated magenta a data series gets.
      assert fill(solid) == "#e10095"
      assert fill(surface) != fill(solid)
    end

    test "the surface tone is strongly desaturated, keeping only a hint of the hue" do
      for index <- 0..4 do
        solid = fill(Svg.render(frame(%{polys: [poly(square(0), index, 1.0, :solid)]})))
        surface = fill(Svg.render(frame(%{polys: [poly(square(0), index, 1.0, :surface)]})))

        # Not merely "a different hex": most of the chroma is gone.
        assert spread(surface) < spread(solid) / 3,
               "slot #{index}: #{surface} (spread #{spread(surface)}) is not much quieter " <>
                 "than #{solid} (spread #{spread(solid)})"
      end
    end

    test "surfaces still differ from each other, so two backdrops are told apart" do
      tones =
        for index <- 0..4 do
          fill(Svg.render(frame(%{polys: [poly(square(0), index, 1.0, :surface)]})))
        end

      assert length(Enum.uniq(tones)) == 5
      # Pinned: a mid-grey mix keeps "quiet" the same lightness across all five
      # slots, which mixing toward each colour's own luminance would not.
      assert tones == ["#a07162", "#608894", "#8566a0", "#986085", "#8b8460"]
    end

    test "a surface is painted with alpha, which is how it works on BOTH grounds" do
      svg = Svg.render(frame(%{polys: [poly(square(0), 3, 1.0, :surface)]}))

      # We do not know the theme at render time, so we never blend toward a
      # ground hex we picked — we let the browser composite against the real one.
      # This is the fill-side twin of `currentColor` on the labels.
      assert svg =~ ~s(fill-opacity="0.18")
      assert svg =~ ~s(stroke-opacity="0.4")
      parse!(svg)
    end

    test "a solid carries no alpha at all — only backdrops are washed out" do
      svg = Svg.render(frame(%{polys: [poly(square(0), 3, 1.0, :solid)]}))

      refute svg =~ "fill-opacity"
      refute svg =~ "stroke-opacity"
    end

    test "the surface edge is quiet and shares the fill's tone, not a darkened one" do
      svg = Svg.render(frame(%{polys: [poly(square(0), 1, 1.0, :surface)]}))

      # Same tone, less transparent: a discernible boundary on both grounds
      # without a frame. @edge_factor's darkening would sink it into #121212.
      assert svg =~ ~s(fill="#608894")
      assert svg =~ ~s(stroke="#608894")
      assert svg =~ ~s(vector-effect="non-scaling-stroke")
    end

    test "a poly with no role at all still reads as a solid" do
      # A subject drawn as a backdrop is gone; a backdrop drawn as a subject is
      # merely ugly. The default has to be the loud one.
      svg = Svg.render(frame(%{polys: [%{points: square(0), color: 3, shade: 1.0, depth: 0.0}]}))

      assert fill(svg) == "#e10095"
      refute svg =~ "fill-opacity"
    end

    test "surfaces and solids in one frame keep their own treatment and their order" do
      svg =
        Svg.render(
          frame(%{
            polys: [poly(square(0), 3, 1.0, :surface), poly(square(20), 3, 1.0, :solid)]
          })
        )

      assert fills(svg) == ["#986085", "#e10095"]
      parse!(svg)
    end
  end

  describe "label layout is delegated to Scene3d.Labels" do
    test "each label renders at its own size, and there is no global one" do
      svg =
        Svg.render(
          frame(%{labels: [label({0.0, 0.0}, "big"), label({1.0, 1.0}, "small")]}),
          layout([placed({10.0, 10.0}, "big", 9.0), placed({30.0, 30.0}, "small", 3.25)])
        )

      assert svg =~ ~s(font-size="9")
      assert svg =~ ~s(font-size="3.25")
      # Exactly two font-size attributes: the group no longer carries one, which
      # is what "individual sizes" has to mean.
      assert length(String.split(svg, "font-size=")) == 3
      parse!(svg)
    end

    test "a label is drawn where layout put it, not where it was anchored" do
      svg =
        Svg.render(
          frame(%{labels: [label({0.0, 0.0}, "sound")]}),
          layout([placed({42.0, 7.0}, "sound", 5.0, anchor: {0.0, 0.0}, leader: true)])
        )

      assert svg =~ ~s(<text x="42" y="7")
    end

    test "a leader hairline is drawn only for leader: true" do
      svg =
        Svg.render(
          frame(%{labels: [label({0.0, 0.0}, "moved"), label({1.0, 1.0}, "put")]}),
          layout([
            placed({40.0, 40.0}, "moved", 5.0, anchor: {2.0, 3.0}, leader: true),
            placed({50.0, 50.0}, "put", 5.0)
          ])
        )

      # One hairline, from the anchor it names to where the label ended up. An
      # offset label with no leader is a label pointing at nothing.
      assert length(String.split(svg, "<line")) == 2
      assert svg =~ ~s(<line x1="2" y1="3" x2="40" y2="40")
      assert svg =~ ~s(stroke="currentColor")
      # Under the text it belongs to, in both senses.
      assert at(svg, "<line") < at(svg, "<text")
      assert svg =~ ~s(stroke-opacity="0.35")
      parse!(svg)
    end

    test "labels absent from the layout result are not drawn" do
      svg =
        Svg.render(
          frame(%{labels: [label({0.0, 0.0}, "kept"), label({1.0, 1.0}, "dropped")]}),
          layout([placed({0.0, 0.0}, "kept", 5.0)])
        )

      assert svg =~ ">kept</text>"
      refute svg =~ ">dropped</text>"
    end

    test "a dropped label still reaches the accessible name" do
      svg =
        Svg.render(
          frame(%{labels: [label({0.0, 0.0}, "kept"), label({1.0, 1.0}, "dropped")]}),
          layout([placed({0.0, 0.0}, "kept", 5.0)])
        )

      # The title is derived from the frame's FULL label list on purpose: dropping
      # a label is a readability trade, not a decision to forget it exists.
      assert svg =~ "<title>3D scene: kept, dropped</title>"
    end

    test "dropping every label leaves no label layer behind" do
      svg = Svg.render(frame(%{labels: [label({0.0, 0.0}, "gone")]}), layout([]))

      refute svg =~ ~s(data-layer="labels")
      refute svg =~ "<text"
      parse!(svg)
    end

    test "layout gets the frame's labels and the widened viewBox" do
      seen = self()

      Svg.render(frame(%{labels: [label({2.0, 3.0}, "x")], viewbox: {0.0, 0.0, 0.0, 0.0}}),
        layout: fn labels, viewbox, _opts ->
          send(seen, {:layout, labels, viewbox})
          []
        end
      )

      # The *rendered* box, not the raw one — a zero box is widened before
      # anything is laid out inside it.
      assert_received {:layout, [%{at: {2.0, 3.0}, text: "x"}], {+0.0, +0.0, 1, 1}}
    end

    test "a malformed label never reaches layout, so delegation cannot break totality" do
      # Phase 1 promises the last stage before the DOM cannot be crashed by a
      # label; handing the work to another module does not hand that promise over
      # with it. (This is not hypothetical: `Labels` charlists the text.)
      seen = self()

      svg =
        Svg.render(
          frame(%{
            labels: [
              label({0.0, 0.0}, nil),
              label(:nowhere, "ok"),
              label({1.0, 1.0}, "real")
            ]
          }),
          layout: fn labels, _viewbox, _opts ->
            send(seen, {:layout, labels})
            []
          end
        )

      assert_received {:layout, [%{text: "real"}]}
      parse!(svg)
    end

    test "layout is not called at all for a frame with no labels" do
      svg =
        Svg.render(frame(%{polys: [poly(square(0), 0)]}), layout: fn _, _, _ -> raise "no" end)

      assert svg =~ "<polygon"
    end
  end

  describe "empty and degenerate frames" do
    test "an empty frame yields a valid, empty svg rather than garbage" do
      svg = Svg.render(frame())

      parse!(svg)
      assert svg =~ ~s(<svg xmlns="http://www.w3.org/2000/svg")
      assert String.ends_with?(svg, "</svg>")
      refute svg =~ "<polygon"
      refute svg =~ "<line"
      refute svg =~ "<text"
      # No empty layer groups either — an empty scene is an empty card.
      refute svg =~ "data-layer"
      assert svg =~ "<title>3D scene</title>"
    end

    test "a zero-sized viewBox is widened, because a zero box renders nothing at all" do
      svg = Svg.render(frame(%{viewbox: {0.0, 0.0, 0.0, 0.0}}))

      assert svg =~ ~s(viewBox="0 0 1 1")
      parse!(svg)
    end

    test "a large frame stays well-formed" do
      polys = for i <- 1..500, do: poly(square(i * 1.5), rem(i, 5), rem(i, 10) / 10)
      svg = Svg.render(frame(%{polys: polys, viewbox: {0.0, 0.0, 800.0, 800.0}}))

      parse!(svg)
      assert length(String.split(svg, "<polygon")) == 501
    end
  end

  # Every text node in document order — proves label content round-trips through
  # a real parser as data, never as markup.
  defp texts(node), do: node |> collect_texts() |> List.flatten()

  defp collect_texts({:xmlElement, _n, _en, _ns, _ns2, _p, _pos, _attrs, content, _l, _x, _y}) do
    Enum.map(content, &collect_texts/1)
  end

  defp collect_texts({:xmlText, _parents, _pos, _lang, value, _type}), do: [to_string(value)]
  defp collect_texts(_other), do: []
end
