defmodule BusterClaw.Sketch.DocumentTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Sketch.{Document, Element}

  defp element!(overrides \\ %{}) do
    {:ok, element} =
      Map.merge(
        %{"kind" => "stroke", "points" => [[0, 0], [10, 10]], "color" => "#FF4D1C", "width" => 2},
        overrides
      )
      |> Element.new()

    element
  end

  defp doc_with(n) when is_integer(n) do
    Enum.reduce(1..n, Document.new(), fn i, doc ->
      Document.add(doc, element!(%{"points" => [[i, i], [i + 1, i + 1]]}))
    end)
  end

  describe "adding" do
    test "a new document is empty and stamped" do
      doc = Document.new()

      assert doc.elements == []
      assert Document.size(doc) == 0
      assert String.starts_with?(doc.id, "sk_")
      assert %DateTime{} = doc.created_at
    end

    test "add appends, so list order is paint order" do
      first = element!()
      second = element!()

      doc = Document.new() |> Document.add(first) |> Document.add(second)

      assert Enum.map(doc.elements, & &1.id) == [first.id, second.id]
    end
  end

  describe "deleting" do
    # The whole point of Phase 1, and the thing a bitmap cannot do: remove one
    # mark and leave every other one exactly as it was.
    test "removes one element and touches nothing else" do
      doc = doc_with(5)
      [_, second | _] = doc.elements
      before = Enum.reject(doc.elements, &(&1.id == second.id))

      assert {:ok, after_delete} = Document.delete(doc, second.id)
      assert after_delete.elements == before
      assert Document.size(after_delete) == 4
      assert Document.find(after_delete, second.id) == nil
    end

    test "an id that is not here is an error, not a silent no-op" do
      # Phase 3 hands these ids to a model. "The delete did nothing" is the
      # failure that cannot be diagnosed from outside.
      assert :error = Document.delete(doc_with(3), "el_nope")
      assert :error = Document.delete(doc_with(3), nil)
    end
  end

  describe "moving" do
    test "translates every point and leaves the rest of the document alone" do
      doc = Document.new() |> Document.add(element!(%{"points" => [[0, 0], [10, 20]]}))
      [element] = doc.elements

      assert {:ok, moved} = Document.move(doc, element.id, {5, -5})
      assert [%{points: [[5.0, -5.0], [15.0, 15.0]]}] = moved.elements
    end

    test "moving does not change z-order" do
      # Moving something is not the same as raising it. A move that reordered
      # would make the drawing rearrange itself under a drag.
      doc = doc_with(3)
      ids = Enum.map(doc.elements, & &1.id)
      [_, middle | _] = ids

      assert {:ok, moved} = Document.move(doc, middle, {100, 100})
      assert Enum.map(moved.elements, & &1.id) == ids
    end

    test "an unknown id is an error" do
      assert :error = Document.move(doc_with(2), "el_nope", {1, 1})
    end
  end

  describe "clear" do
    test "empties the elements but keeps the document's identity" do
      # Clearing a sketch is not starting a different one, and undo has to be
      # able to bring the elements back to *this* document.
      doc = doc_with(4)
      cleared = Document.clear(doc)

      assert cleared.elements == []
      assert cleared.id == doc.id
      assert cleared.created_at == doc.created_at
    end
  end

  describe "operations are pure, which is what makes undo a value" do
    test "every operation returns a new document and leaves the old one intact" do
      doc = doc_with(3)
      [first | _] = doc.elements

      {:ok, deleted} = Document.delete(doc, first.id)
      {:ok, moved} = Document.move(doc, first.id, {10, 10})
      cleared = Document.clear(doc)

      # Undo is "keep the previous one". That is only sound if the previous one
      # is genuinely unchanged by what came after it.
      assert Document.size(doc) == 3
      assert Document.size(deleted) == 2
      assert Document.size(moved) == 3
      assert Document.size(cleared) == 0
      assert Document.find(doc, first.id).points == [[1.0, 1.0], [2.0, 2.0]]
    end
  end
end
