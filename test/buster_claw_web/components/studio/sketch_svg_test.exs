defmodule BusterClawWeb.Studio.SketchSvgTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias BusterClaw.Sketch.Element
  alias BusterClaw.Sketch.Svg
  alias BusterClawWeb.Studio.SketchSvg

  defp element!(overrides \\ %{}) do
    {:ok, element} =
      Map.merge(
        %{"kind" => "stroke", "points" => [[0, 0], [10, 10]], "color" => "#FF4D1C", "width" => 2},
        overrides
      )
      |> Element.new()

    element
  end

  defp surface(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{elements: [], selected: nil, tool: :draw, target: "#sketch", sketch: "untitled"},
        overrides
      )

    render_component(&SketchSvg.surface/1, assigns)
  end

  defp image!(overrides \\ %{}) do
    {:ok, element} =
      Map.merge(
        %{
          "kind" => "image",
          "source" => "0123456789abcdef.png",
          "x" => 10,
          "y" => 20,
          "w" => 100,
          "h" => 50
        },
        overrides
      )
      |> Element.new()

    element
  end

  defp text!(overrides \\ %{}) do
    {:ok, element} =
      Map.merge(
        %{
          "kind" => "text",
          "content" => "Hello",
          "color" => "#1C9BFF",
          "size" => 18,
          "x" => 10,
          "y" => 20
        },
        overrides
      )
      |> Element.new()

    element
  end

  describe "path_data/1 agrees with the JavaScript renderer" do
    # These are the SAME cases asserted in `assets/js/lib/sketch.test.js`. The
    # hook draws a stroke while it is being made and this draws it the instant it
    # commits; a disagreement is not a rendering bug, it is a visible jump at the
    # end of every stroke. Two implementations exist because one runs in each
    # place — this is what keeps them one behaviour.
    test "the shared cases produce byte-identical strings" do
      assert Svg.path_data([[1.5, 2.5]]) == "M 1.5 2.5 L 1.5 2.5"
      assert Svg.path_data([[0.0, 0.0], [1.1, 2.2]]) == "M 0 0 L 1.1 2.2"

      assert Svg.path_data([[-5.0, 10.0], [0.0, 0.0], [5.5, -10.5]]) ==
               "M -5 10 L 0 0 L 5.5 -10.5"

      assert Svg.path_data([[7.0, 3.0]]) == "M 7 3 L 7 3"
      assert Svg.path_data([]) == ""
    end

    test "a whole number prints without a trailing .0" do
      # Elements store floats, so every whole coordinate is `0.0` here and `0` in
      # JavaScript. Both are valid SVG and the strings differ, which is exactly
      # the drift this file exists to catch.
      assert Svg.path_data([[0.0, 0.0], [16.0, 16.0]]) == "M 0 0 L 16 16"
      refute Svg.path_data([[0.0, 0.0]]) =~ "0.0"
    end

    test "a malformed point list renders nothing rather than a broken path" do
      assert Svg.path_data(nil) == ""
      assert Svg.path_data("nope") == ""
    end
  end

  describe "the surface" do
    test "renders one visible path per element" do
      html = surface(%{elements: [element!(), element!(%{"color" => "#2FD068"})]})

      assert html =~ ~s(stroke="#FF4D1C")
      assert html =~ ~s(stroke="#2FD068")
    end

    test "widths print like coordinates do" do
      assert surface(%{elements: [element!(%{"width" => 16})]}) =~ ~s(stroke-width="16")
    end

    test "the in-flight layer is protected from LiveView" do
      # The hook rewrites this path's `d` on every pointermove. A re-render
      # between two of them erases the stroke mid-draw.
      html = surface()

      assert html =~ ~s(id="studio-sketch-live")
      assert html =~ ~s(phx-update="ignore")
      assert html =~ "data-sketch-live"
    end

    test "the surface carries the component as its event target" do
      # Without this every event the hook pushes lands on the parent LiveView,
      # which has no clause for it and raises.
      assert surface() =~ ~s(phx-target="#sketch")
    end
  end

  describe "hit targets exist only where pointing at something is the job" do
    test "draw mode renders none, so a stroke can start anywhere" do
      html = surface(%{elements: [element!()], tool: :draw})

      refute html =~ "data-sketch-element",
             "a hit target in draw mode swallows the pointerdown that starts a stroke"
    end

    test "erase and select render one per element, wide enough to hit" do
      for tool <- [:erase, :select] do
        html = surface(%{elements: [element!()], tool: tool})

        assert html =~ "data-sketch-element", "#{tool} needs something to point at"
        assert html =~ ~s(stroke-width="#{SketchSvg.hit_width()}")
        assert html =~ ~s(pointer-events="stroke")
      end
    end

    test "a thick stroke keeps its own width as the hit area" do
      # `max` — a 40px stroke should not shrink to a 16px target.
      html = surface(%{elements: [element!(%{"width" => 40})], tool: :select})

      assert html =~ ~s(stroke-width="40")
    end
  end

  describe "selection" do
    test "the selected element gets a ring drawn along its own path" do
      # A bounding box round a freehand stroke is mostly empty, so it would
      # point at the wrong thing.
      element = element!()
      html = surface(%{elements: [element], selected: element.id, tool: :select})

      assert html =~ "text-primary"
      assert html =~ ~s(stroke-width="8"), "the ring should be wider than the 2px stroke"
    end

    test "nothing is ringed when nothing is selected" do
      refute surface(%{elements: [element!()], tool: :select}) =~ "text-primary"
    end
  end

  describe "images" do
    test "an image renders as an <image> pointing at the sketch's sidecar" do
      html = surface(%{elements: [image!()]})

      assert html =~ ~s(href="/sketches/untitled/0123456789abcdef.png")
      assert html =~ ~s(x="10")
      assert html =~ ~s(width="100")
      assert html =~ ~s(height="50")
    end

    test "the URL follows the sketch, not a hardcoded name" do
      html = surface(%{elements: [image!()], sketch: "kitchen plan"})

      assert html =~ "/sketches/kitchen%20plan/0123456789abcdef.png"
    end

    test "the bytes are never in the document" do
      # An image REFERENCES a file. A base64 blob here could not be diffed or
      # grepped, and would put arbitrary bytes into whatever the audit captures.
      refute surface(%{elements: [image!()]}) =~ "data:image"
    end

    test "an image is selected with a box; a stroke is not" do
      # The two kinds want opposite treatment. A freehand stroke's bounding box
      # is mostly empty, so a box would point at the wrong thing — but an image
      # IS its box.
      element = image!()
      html = surface(%{elements: [element], selected: element.id, tool: :select})

      assert html =~ "<rect"
      assert html =~ "text-primary"
    end

    test "an image is picked up anywhere inside it, not along an edge" do
      # `pointer-events="all"` on a transparent FILL. `stroke` would only hit the
      # one-pixel border, which is unusable.
      html = surface(%{elements: [image!()], tool: :select})

      assert html =~ ~s(fill="transparent")
      assert html =~ ~s(pointer-events="all")
      assert html =~ "data-sketch-element"
    end

    test "no hit target in draw mode, same as strokes" do
      refute surface(%{elements: [image!()], tool: :draw}) =~ "data-sketch-element"
    end
  end

  describe "text, in the pure renderer" do
    defp document(elements) do
      Enum.reduce(
        elements,
        BusterClaw.Sketch.Document.new(),
        &BusterClaw.Sketch.Document.add(&2, &1)
      )
    end

    test "a label renders as an <text> carrying its own content" do
      svg = Svg.to_document(document([text!(%{"content" => "Kitchen"})]))

      assert svg =~ ">Kitchen</text>"
      assert svg =~ ~s(fill="#1C9BFF")
      assert svg =~ ~s(font-size="18")
    end

    test "markup in a label is ESCAPED, and this is the assertion that matters" do
      # From Phase 3 on, `content` is model-supplied and lands as SVG **text
      # content** — the only field on any element that is not a number or an
      # allowlisted colour. `Element` strips control characters and caps the
      # length; it deliberately does not strip markup, so the escape is here or
      # it is nowhere. Asserted against the raw output string rather than a
      # parsed tree, because a parser would happily hide the failure by
      # re-escaping on the way out.
      svg = Svg.to_document(document([text!(%{"content" => ~s(a & b <g> "q" 'p')})]))

      assert svg =~ ~s(>a &amp; b &lt;g&gt; &quot;q&quot; &#39;p&#39;</text>)

      refute svg =~ "<g>", "a label opened a real SVG element"
      refute svg =~ "&amp;amp;", "the ampersand was escaped twice"
    end

    test "a script tag in a label cannot become one" do
      svg = Svg.to_document(document([text!(%{"content" => "<script>alert(1)</script>"})]))

      refute svg =~ "<script"
      refute svg =~ "</script>"
      assert svg =~ "&lt;script&gt;"
    end

    test "a label-only sketch is big enough to contain its label" do
      # Without an extent clause a text-only document renders at the floor size
      # and anything placed past it falls outside the frame — a preview of a
      # blank rectangle, which is worse than one that is a little too generous.
      label = text!(%{"x" => 800, "y" => 700, "content" => "far"})
      svg = Svg.to_document(document([label]))

      [_, side] = Regex.run(~r/ width="([\d.]+)"/, svg)
      {side, _rest} = Float.parse(side)

      assert side > label.x + Svg.text_width(label)
      assert side > label.y + Svg.text_height(label)
    end

    test "the baseline sits below the element's y, because y is the top" do
      # SVG's `y` on a <text> is the baseline and every other kind here places by
      # its top-left. The element's convention won; this is the offset that pays
      # for it, and both renderers read it from the same function.
      label = text!(%{"y" => 20, "size" => 18})

      assert Svg.text_baseline(label) == 20.0 + 18 * 0.8
      assert Svg.to_document(document([label])) =~ ~s(y="34.4")
    end
  end

  describe "text, on the live surface" do
    test "a label renders with its content, its colour and its size" do
      html = surface(%{elements: [text!(%{"content" => "Kitchen"})]})

      assert html =~ "Kitchen"
      assert html =~ "<text"
      assert html =~ ~s(fill="#1C9BFF")
      assert html =~ ~s(font-size="18")
    end

    test "HEEx escapes the content, and exactly once" do
      # The interpolation is escaped by the template engine. A second escape
      # added here "for safety" would render `&amp;` where the operator typed
      # `&` — the failure this asserts against.
      html = surface(%{elements: [text!(%{"content" => "a & b <g>"})]})

      assert html =~ ">a &amp; b &lt;g&gt;</text>"
      refute html =~ "&amp;amp;"
    end

    test "a label gets a hit target in the tools that point at things" do
      for tool <- [:erase, :select] do
        html = surface(%{elements: [text!()], tool: tool})

        assert html =~ "data-sketch-element", "#{tool} needs something to point at"
        # Picked up by its box, not by its glyphs — `pointer-events` on the
        # letters themselves leaves the counter of an `o` as a hole.
        assert html =~ ~s(fill="transparent")
        assert html =~ ~s(pointer-events="all")
      end
    end

    test "no hit target in draw mode, and none in text mode either" do
      # Draw: a target there swallows the pointerdown that starts a stroke.
      # Text: the tool places a label wherever it is clicked and never points at
      # an existing element, so a target there is a node that does nothing.
      for tool <- [:draw, :text] do
        refute surface(%{elements: [text!()], tool: tool}) =~ "data-sketch-element",
               "#{tool} mode rendered a hit target"
      end
    end

    test "a selected label is ringed by its estimated box" do
      element = text!(%{"content" => "abcde", "size" => 18})
      html = surface(%{elements: [element], selected: element.id, tool: :select})

      assert html =~ "text-primary"
      assert html =~ ~s(height="21.6)
    end

    test "the width estimate follows the content, since nothing can measure it" do
      short = Svg.text_width(text!(%{"content" => "ab"}))
      long = Svg.text_width(text!(%{"content" => "abcdefghij"}))

      assert long > short
      assert Svg.text_width(text!(%{"content" => "ab", "size" => 48})) > short
    end
  end

  describe "attribution is visible — D7" do
    test "a model-authored mark carries a marker an operator's does not" do
      # D6 lets the model delete only what the model drew. That rule reads as
      # arbitrary unless the surface shows which marks are which, so this is a
      # requirement rather than decoration.
      mine = surface(%{elements: [element!()]})
      theirs = surface(%{elements: [element!(%{"author" => "model"})]})

      refute mine =~ ~s(data-sketch-author="model")
      assert theirs =~ ~s(data-sketch-author="model")
      assert theirs =~ "Drawn by the model"
    end

    test "every kind is attributed, not only strokes" do
      for element <- [element!(), image!(), text!()] do
        html = surface(%{elements: [%{element | author: :model}]})

        assert html =~ ~s(data-sketch-author="model"),
               "a model-authored #{element.kind} showed no attribution"
      end
    end

    test "the marker sits beside the mark and never tints it" do
      # Tinting model work would change what the drawing looks like, which is the
      # one thing a drawing surface may not do to a drawing — the same reason the
      # eraser stopped painting background-coloured strokes.
      theirs = surface(%{elements: [element!(%{"author" => "model"})]})

      assert theirs =~ ~s(stroke="#FF4D1C"), "the mark's own colour changed"
      assert theirs =~ ~s(width="#{SketchSvg.marker_size()}")
    end

    test "a mark at the origin still gets a marker on the canvas" do
      # There is no viewBox, so a negative coordinate is simply clipped — an
      # unclamped offset would silently drop the attribution for anything drawn
      # against the top-left edge, which is exactly where a first mark lands.
      html =
        surface(%{elements: [element!(%{"points" => [[0, 0], [5, 5]], "author" => "model"})]})

      assert html =~ ~s(<rect data-sketch-author="model" x="1" y="1")
    end
  end

  describe "the marks in one sketch" do
    test "a stroke and a text on one sketch each render their own kind" do
      html = surface(%{elements: [element!(), text!()]})

      assert html =~ "<text"
      assert html =~ "<path"
      refute html =~ ~s(d="" stroke=), "a label rendered as an empty path"
    end

    test "a stroke and an image on one sketch each render their own kind" do
      # `:if={element.kind == ...}` on every branch. Without it an image would be
      # handed to `path_data(element.points)` — nil — and render as an empty path.
      html = surface(%{elements: [element!(), image!()]})

      assert html =~ "<image"
      assert html =~ "<path"
      refute html =~ ~s(d="" stroke="#FF4D1C"), "an image rendered as an empty path"
    end
  end
end
