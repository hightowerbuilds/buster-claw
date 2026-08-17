defmodule BusterClaw.Sketch.ElementTest do
  # The validation boundary. Only the operator writes through it today; it is
  # built for Phase 3, when `sketch_add` starts taking this shape from a model
  # and every field below ends up inside an SVG attribute.
  use ExUnit.Case, async: true

  alias BusterClaw.Sketch.Element

  defp stroke(overrides \\ %{}) do
    Map.merge(
      %{"kind" => "stroke", "points" => [[0, 0], [10, 10]], "color" => "#FF4D1C", "width" => 2},
      overrides
    )
  end

  describe "minting an element" do
    test "builds a stroke and stamps it" do
      assert {:ok, element} = Element.new(stroke())

      assert element.kind == :stroke
      assert element.author == :operator
      assert element.color == "#FF4D1C"
      assert element.width == 2.0
      assert %DateTime{} = element.created_at
    end

    test "ids are minted here, and a supplied one is ignored" do
      # The load-bearing one for D6. If a writer could choose an id, it could
      # overwrite or delete an element it does not own by guessing — which is the
      # authorship boundary defeated by a field.
      assert {:ok, element} = Element.new(stroke(%{"id" => "el_someone_elses"}))

      refute element.id == "el_someone_elses"
      assert String.starts_with?(element.id, "el_")
    end

    test "two elements never share an id" do
      ids = for _ <- 1..200, {:ok, e} = Element.new(stroke()), do: e.id

      assert length(Enum.uniq(ids)) == 200
    end

    test "atom keys work as well as string keys" do
      assert {:ok, _} =
               Element.new(%{kind: "stroke", points: [[1, 1]], color: "#121212", width: 6})
    end
  end

  describe "author" do
    test "defaults to the operator" do
      # Not a convenience. A document that silently claimed `:model` authorship
      # would hand the model deletion rights over the operator's own strokes.
      assert {:ok, %{author: :operator}} = Element.new(stroke())
    end

    test "accepts the two that exist and refuses anything else" do
      assert {:ok, %{author: :model}} = Element.new(stroke(%{"author" => "model"}))
      assert {:error, {:unknown_author, "admin"}} = Element.new(stroke(%{"author" => "admin"}))
    end
  end

  describe "colour is an allowlist, because it lands in an SVG attribute" do
    test "six hex digits after a hash, and nothing else" do
      assert {:ok, _} = Element.new(stroke(%{"color" => "#0a1B2c"}))

      for bad <- ["red", "#FFF", "#GGGGGG", "#FF4D1C;", "", "#FF4D1C\" onload=\"x"] do
        assert {:error, {:bad_color, ^bad}} = Element.new(stroke(%{"color" => bad})),
               "#{inspect(bad)} should not be accepted as a colour"
      end
    end

    test "a non-string colour is refused rather than coerced" do
      assert {:error, :missing_color} = Element.new(stroke(%{"color" => 16_724_508}))
    end
  end

  describe "points" do
    test "an empty or missing stroke is not an element" do
      assert {:error, :empty_points} = Element.new(stroke(%{"points" => []}))
      assert {:error, :missing_points} = Element.new(stroke(%{"points" => nil}))
    end

    test "malformed points are refused, not skipped" do
      # Skipping would produce a stroke that renders as something the writer did
      # not ask for, which is worse than refusing the whole thing.
      assert {:error, :malformed_point} = Element.new(stroke(%{"points" => [[1, 2], [3]]}))
      assert {:error, :malformed_point} = Element.new(stroke(%{"points" => [["1", "2"]]}))
      assert {:error, :malformed_point} = Element.new(stroke(%{"points" => [%{"x" => 1}]}))
    end

    test "coordinates are bounded" do
      assert {:error, :point_out_of_bounds} = Element.new(stroke(%{"points" => [[0, 1.0e9]]}))
    end

    test "there is a ceiling on how long a stroke can be" do
      long = for i <- 1..5_000, do: [i, i]

      assert {:error, :too_many_points} = Element.new(stroke(%{"points" => long}))
    end

    test "coordinates are rounded to one decimal" do
      # Below what any display resolves, and roughly halves what a long freehand
      # stroke costs in the file and in every LiveView diff.
      assert {:ok, %{points: [[1.1, 2.5]]}} =
               Element.new(stroke(%{"points" => [[1.14159, 2.46]]}))
    end
  end

  describe "width" do
    test "must be positive and bounded" do
      assert {:error, :width_out_of_range} = Element.new(stroke(%{"width" => 0}))
      assert {:error, :width_out_of_range} = Element.new(stroke(%{"width" => -4}))
      assert {:error, :width_out_of_range} = Element.new(stroke(%{"width" => 10_000}))
    end
  end

  describe "kind" do
    test "an unknown kind is refused rather than stored" do
      # A document can never carry something no renderer knows how to draw.
      assert {:error, {:unknown_kind, "hologram"}} = Element.new(stroke(%{"kind" => "hologram"}))
      assert {:error, :missing_kind} = Element.new(%{"points" => [[0, 0]]})
    end

    test "the kinds that exist are the kinds that render" do
      # A kind here with no clause in `Studio.SketchSvg` is a document that can
      # hold something nothing can draw. Grew from [:stroke] when Phase 4 added
      # images; the next kinds arrive with the phases that need them.
      assert Element.kinds() == [:stroke, :image, :text]
    end
  end

  describe "images" do
    defp image(overrides \\ %{}) do
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
    end

    test "an image references a file and carries no bytes" do
      assert {:ok, element} = Element.new(image())

      assert element.kind == :image
      assert element.source == "0123456789abcdef.png"
      assert {element.x, element.y, element.w, element.h} == {10.0, 20.0, 100.0, 50.0}
      assert element.points == nil
    end

    test "the source must be a name Assets minted, and nothing else" do
      # The same allowlist `Sketch.Assets` writes against. This is where a model
      # will hand one over in Phase 4, so it is checked rather than trusted —
      # and nothing shaped like a path matches, so there is no traversal to strip.
      for bad <- [
            "../../etc/passwd",
            "0123456789abcdef.svg",
            "0123456789abcdef.png/../x",
            "not-a-hash.png",
            "0123456789ABCDEF.png",
            "0123456789abcdef.png ",
            ""
          ] do
        assert {:error, {:bad_source, ^bad}} = Element.new(image(%{"source" => bad})),
               "#{inspect(bad)} should not be accepted as an image source"
      end
    end

    test "a missing source is refused" do
      assert {:error, :missing_source} = Element.new(image(%{"source" => nil}))
    end

    test "position and size must be present and sane" do
      assert {:error, :missing_x} = Element.new(image(%{"x" => nil}))
      assert {:error, :missing_y} = Element.new(image(%{"y" => "20"}))
      assert {:error, :extent_out_of_range} = Element.new(image(%{"w" => 0}))
      assert {:error, :extent_out_of_range} = Element.new(image(%{"h" => -5}))
      assert {:error, :extent_out_of_range} = Element.new(image(%{"w" => 50_000}))
    end

    test "an image does not need the fields a stroke needs" do
      # Kinds are validated by their own clause. If `build/2` fell through to a
      # shared validator, an image would be refused for having no colour.
      assert {:ok, _} = Element.new(image())

      assert {:error, :missing_points} =
               Element.new(%{"kind" => "stroke", "color" => "#FF4D1C", "width" => 2})
    end

    test "an image round-trips through rehydrate" do
      {:ok, original} = Element.new(image())

      attrs = %{
        "id" => original.id,
        "kind" => "image",
        "author" => "operator",
        "source" => original.source,
        "x" => 10,
        "y" => 20,
        "w" => 100,
        "h" => 50
      }

      assert {:ok, restored} = Element.rehydrate(attrs)
      assert restored.source == original.source
      assert restored.w == 100.0
    end
  end

  describe "rehydrate/1 — reading one back off disk" do
    test "keeps the stored id, author and timestamp" do
      {:ok, original} = Element.new(stroke(%{"author" => "model"}))

      attrs = %{
        "id" => original.id,
        "kind" => "stroke",
        "author" => "model",
        "created_at" => DateTime.to_iso8601(original.created_at),
        "points" => [[0, 0], [5, 5]],
        "color" => "#2FD068",
        "width" => 6
      }

      assert {:ok, restored} = Element.rehydrate(attrs)
      assert restored.id == original.id
      assert restored.author == :model
      assert DateTime.compare(restored.created_at, original.created_at) == :eq
    end

    test "an element with no id cannot be rehydrated" do
      # `new/1` mints one; `rehydrate/1` must not, or a hand-edited file would
      # gain elements with fresh ids on every load and undo would address ghosts.
      assert {:error, :missing_id} = Element.rehydrate(stroke())
    end

    test "still validates every other field" do
      attrs = stroke(%{"id" => "el_x", "color" => "javascript:alert(1)"})

      assert {:error, {:bad_color, _}} = Element.rehydrate(attrs)
    end
  end
end
