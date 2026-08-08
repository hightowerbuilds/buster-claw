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

  defp poly(points, color, shade \\ 1.0, depth \\ 0.0) do
    %{points: points, color: color, shade: shade, depth: depth}
  end

  defp line(a, b, color, width \\ 2.0, depth \\ 0.0) do
    %{a: a, b: b, color: color, width: width, depth: depth}
  end

  defp label(at, text, depth \\ 0.0), do: %{at: at, text: text, depth: depth}

  defp square(offset) do
    [{offset, offset}, {offset + 10, offset}, {offset + 10, offset + 10}, {offset, offset + 10}]
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

      assert svg =~ "<text"
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
