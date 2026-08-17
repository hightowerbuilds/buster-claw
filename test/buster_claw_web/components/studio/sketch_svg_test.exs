defmodule BusterClawWeb.Studio.SketchSvgTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias BusterClaw.Sketch.Element
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

  describe "path_data/1 agrees with the JavaScript renderer" do
    # These are the SAME cases asserted in `assets/js/lib/sketch.test.js`. The
    # hook draws a stroke while it is being made and this draws it the instant it
    # commits; a disagreement is not a rendering bug, it is a visible jump at the
    # end of every stroke. Two implementations exist because one runs in each
    # place — this is what keeps them one behaviour.
    test "the shared cases produce byte-identical strings" do
      assert SketchSvg.path_data([[1.5, 2.5]]) == "M 1.5 2.5 L 1.5 2.5"
      assert SketchSvg.path_data([[0.0, 0.0], [1.1, 2.2]]) == "M 0 0 L 1.1 2.2"

      assert SketchSvg.path_data([[-5.0, 10.0], [0.0, 0.0], [5.5, -10.5]]) ==
               "M -5 10 L 0 0 L 5.5 -10.5"

      assert SketchSvg.path_data([[7.0, 3.0]]) == "M 7 3 L 7 3"
      assert SketchSvg.path_data([]) == ""
    end

    test "a whole number prints without a trailing .0" do
      # Elements store floats, so every whole coordinate is `0.0` here and `0` in
      # JavaScript. Both are valid SVG and the strings differ, which is exactly
      # the drift this file exists to catch.
      assert SketchSvg.path_data([[0.0, 0.0], [16.0, 16.0]]) == "M 0 0 L 16 16"
      refute SketchSvg.path_data([[0.0, 0.0]]) =~ "0.0"
    end

    test "a malformed point list renders nothing rather than a broken path" do
      assert SketchSvg.path_data(nil) == ""
      assert SketchSvg.path_data("nope") == ""
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
