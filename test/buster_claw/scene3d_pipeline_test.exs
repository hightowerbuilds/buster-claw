defmodule BusterClaw.Scene3dPipelineTest do
  @moduledoc """
  End-to-end tests for the Scene3D pipeline.

  The four stages were built independently against `BusterClaw.Scene3d.Types`,
  and each has thorough unit tests of its own. Those tests cannot catch a
  **seam** defect — a stage satisfying the contract's letter while handing the
  next stage something it cannot use. This file only exercises the whole chain,
  from the text an assistant emits to the SVG string a card renders.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Scene3d

  # A scene using every joint in the pipeline at once: several primitives, a
  # composition helper, labels, an explicit palette index, and a line.
  defp reply do
    """
    Here is how the ingest path fits together.

    ```scene3d
    {"camera": {"azimuth": 40, "elevation": 20},
     "nodes": [
       {"kind": "box", "size": [2,1,1], "at": [0,0,0], "label": "API", "color": 1},
       {"kind": "cylinder", "r": 0.5, "h": 2, "at": [4,0,0], "label": "Queue", "color": 2},
       {"kind": "arrow", "from": [1,0,0], "to": [3.5,0,0], "label": "publish"},
       {"kind": "grid", "count": [2,1,2], "gap": 1.2, "at": [0,0,-5],
        "child": {"kind": "box", "size": [0.6,0.6,0.6], "color": 3}}
     ]}
    ```

    The queue fans out to the workers behind it.
    """
  end

  describe "the whole chain" do
    test "an assistant reply yields clean text and a rendered SVG card" do
      {clean, [body]} = Scene3d.extract(reply())

      refute clean =~ "scene3d"
      refute clean =~ "camera"
      assert clean =~ "ingest path"
      assert clean =~ "fans out"

      assert {:ok, svg} = Scene3d.render(body)
      assert svg =~ ~r/\A<svg\b/
      assert svg =~ "</svg>"
      assert svg =~ "viewBox="
    end

    test "labels survive the whole chain and reach the output as text" do
      {_clean, [body]} = Scene3d.extract(reply())
      {:ok, svg} = Scene3d.render(body)

      for label <- ~w(API Queue publish) do
        assert svg =~ label, "label #{inspect(label)} was lost between author and output"
      end
    end

    test "geometry actually reaches the output — the card is not an empty frame" do
      {_clean, [body]} = Scene3d.extract(reply())
      {:ok, svg} = Scene3d.render(body)

      # A box, a cylinder, a capsule-less arrow head and a 2x2 grid of boxes is
      # comfortably over a hundred faces; the exact count is a rendering detail,
      # but "some polygons were drawn" is the seam this asserts.
      polygons = svg |> String.split("<polygon") |> length()
      assert polygons > 20, "expected many polygons, got #{polygons - 1}"
    end

    test "the output parses as well-formed XML" do
      {_clean, [body]} = Scene3d.extract(reply())
      {:ok, svg} = Scene3d.render(body)

      assert {_doc, []} = :xmerl_scan.string(String.to_charlist(svg), quiet: true)
    end
  end

  describe "scale invariance, end to end" do
    # Auto-fit is the property that lets the authoring guide say "any consistent
    # scale works" (roadmap decision 3). It is asserted inside Project's own
    # tests; this pins it survives tessellation and rendering too, since a stage
    # that reintroduced an absolute size would break the promise without
    # breaking Project's tests.
    test "a scene authored 1000x larger renders identically" do
      small = ~s({"nodes": [{"kind": "box", "size": [1,1,1], "at": [0,0,0]}]})
      large = ~s({"nodes": [{"kind": "box", "size": [1000,1000,1000], "at": [0,0,0]}]})

      assert {:ok, a} = Scene3d.render(small)
      assert {:ok, b} = Scene3d.render(large)
      assert a == b
    end
  end

  describe "failure is silent and total" do
    test "a malformed scene returns an error rather than raising" do
      for bad <- [
            "not json at all",
            "{}",
            ~s({"nodes": []}),
            ~s({"nodes": [{"kind": "teapot"}]}),
            ~s({"nodes": [{"kind": "box", "size": [1,1,1], "color": 99}]}),
            ~s({"nodes": [{"kind": "box", "size": [1,1,1], "at": [0,"x",0]}]})
          ] do
        assert {:error, reason} = Scene3d.render(bad)
        assert is_atom(reason), "expected a named reason for #{bad}, got #{inspect(reason)}"
      end
    end

    test "a hostile scene is refused without materialising it" do
      nested =
        ~s({"nodes": [{"kind": "grid", "count": 32, "gap": 1, "child":) <>
          ~s({"kind": "grid", "count": 32, "gap": 1, "child":) <>
          ~s({"kind": "box", "size": [1,1,1]}}}]})

      assert {:error, _} = Scene3d.render(nested)
    end
  end

  describe "the label is the only model-controlled text, and it is escaped" do
    # This is the whole security story of the channel in one test. Unlike
    # `SvgViewer`, nothing here sanitizes model-authored markup, because no
    # model-authored markup exists: the SVG is generated from validated numbers
    # and the only string that survives from the model is a label.
    test "markup in a label reaches the output inert, and still parses" do
      for hostile <- [
            "<script>alert(1)</script>",
            ~s|" onload="steal()|,
            "</text><script>x</script><text>"
          ] do
        json =
          Jason.encode!(%{
            "nodes" => [%{"kind" => "box", "size" => [1, 1, 1], "label" => hostile}]
          })

        assert {:ok, svg} = Scene3d.render(json)

        # The attack is a label escaping its text node to become markup, so the
        # assertions are about TAGS, not substrings. `onload=` sitting inside a
        # <text> body is inert and expected — it is the escaped remains of the
        # attempt — so a bare `refute svg =~ "onload="` would fail on safe output
        # and teach the next reader to weaken the wrong thing.
        refute svg =~ "<script", "a script tag reached the output for #{inspect(hostile)}"

        refute svg =~ ~r/<[^>]*\son[a-z]+\s*=/i,
               "an event-handler attribute reached a tag for #{inspect(hostile)}"

        # Escaped, not stripped: the text must still be there, neutered.
        assert svg =~ "&lt;" or svg =~ "&quot;",
               "label was stripped rather than escaped for #{inspect(hostile)}"

        assert {_doc, []} = :xmerl_scan.string(String.to_charlist(svg), quiet: true)
      end
    end
  end

  describe "the authoring guide" do
    # The guide is the model's only description of a strict vocabulary that
    # fails closed with no feedback loop. Each of these is a rule a scene is
    # rejected for breaking, so a guide that stops mentioning one turns a model
    # error into a silently missing card.
    test "documents every strict edge a scene can be rejected for" do
      guide = Scene3d.guide()

      assert guide =~ "```svg", "the SVG-vs-3D channel distinction is the guide's first job"
      assert guide =~ "scene3d"
      assert guide =~ ~r/plane.*TWO numbers/s
      assert guide =~ ~r/ring takes RADIUS/i
      assert guide =~ ~r/helper rejects them/i
      assert guide =~ ~r/NEVER a hex string/
      assert guide =~ ~r/never set camera distance/i
      assert guide =~ ~r/never make solids intersect/i
    end
  end
end
