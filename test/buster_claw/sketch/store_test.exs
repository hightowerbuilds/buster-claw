defmodule BusterClaw.Sketch.StoreTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Sketch.{Document, Element, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_sketch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp element!(overrides \\ %{}) do
    {:ok, element} =
      Map.merge(
        %{"kind" => "stroke", "points" => [[0, 0], [10, 10]], "color" => "#FF4D1C", "width" => 2},
        overrides
      )
      |> Element.new()

    element
  end

  defp sample do
    Document.new(%{title: "Kitchen plan"})
    |> Document.add(element!())
    |> Document.add(element!(%{"author" => "model", "color" => "#2FD068"}))
  end

  describe "round trip" do
    test "a saved sketch comes back with every element intact" do
      doc = sample()

      assert {:ok, path} = Store.save("plan", doc)
      assert File.exists?(path)
      assert {:ok, loaded} = Store.load("plan")

      assert loaded.title == "Kitchen plan"
      assert loaded.id == doc.id
      assert Enum.map(loaded.elements, & &1.id) == Enum.map(doc.elements, & &1.id)
      assert Enum.map(loaded.elements, & &1.author) == [:operator, :model]
      assert Enum.map(loaded.elements, & &1.points) == Enum.map(doc.elements, & &1.points)
    end

    test "the file is JSON a human can read" do
      # D9: a workspace file the operator owns. If it is not readable it is a
      # database with extra steps.
      {:ok, path} = Store.save("plan", sample())
      raw = File.read!(path)

      assert {:ok, decoded} = Jason.decode(raw)
      assert decoded["version"] == 1
      assert length(decoded["elements"]) == 2
      assert raw =~ "\n  ", "expected pretty-printed JSON"
    end

    test "saving twice replaces rather than appends" do
      {:ok, _} = Store.save("plan", sample())
      {:ok, _} = Store.save("plan", Document.new() |> Document.add(element!()))

      assert {:ok, loaded} = Store.load("plan")
      assert Document.size(loaded) == 1
    end
  end

  describe "names are refused, not sanitised" do
    test "a path is not a name" do
      # Same posture as Pockets: a rewritten path is a path someone chose that we
      # then changed, and the interesting cases are the ones where they meant it.
      for bad <- [
            "../escape",
            "nested/name",
            "back\\slash",
            "",
            ".hidden",
            String.duplicate("x", 80)
          ] do
        assert {:error, :invalid_name} = Store.resolve(bad), "#{inspect(bad)} should be refused"
        assert {:error, :invalid_name} = Store.load(bad)
      end
    end

    test "ordinary names are fine, spaces included" do
      assert {:ok, _} = Store.resolve("plan")
      assert {:ok, _} = Store.resolve("Kitchen plan 2")
      assert {:ok, _} = Store.resolve("a-b_c")
    end

    test "a name never escapes the sketches directory" do
      {:ok, path} = Store.resolve("plan")

      assert Path.dirname(path) == Store.dir()
    end
  end

  describe "loading is an untrusted read" do
    test "a missing sketch is not found" do
      assert {:error, :not_found} = Store.load("nothing")
    end

    test "a file that is not JSON refuses to load rather than reading as empty" do
      # Silently handing back a blank canvas is how someone saves over the
      # drawing they were trying to recover.
      {:ok, path} = Store.resolve("junk")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "this is not json")

      assert {:error, :unreadable} = Store.load("junk")
    end

    test "one corrupt element costs that element, not the drawing" do
      {:ok, path} = Store.save("plan", sample())

      data = path |> File.read!() |> Jason.decode!()
      broken = put_in(data, ["elements", Access.at(0), "color"], "javascript:alert(1)")
      File.write!(path, Jason.encode!(broken))

      assert {:ok, loaded} = Store.load("plan")
      assert Document.size(loaded) == 1, "the valid element should have survived"
      assert hd(loaded.elements).author == :model
    end

    test "an elements key that is not a list loads as empty rather than crashing" do
      {:ok, path} = Store.resolve("weird")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{"version" => 1, "elements" => "nope"}))

      assert {:ok, loaded} = Store.load("weird")
      assert Document.size(loaded) == 0
    end
  end

  describe "listing and deleting" do
    test "lists sketch names alphabetically, ignoring anything else in the folder" do
      for name <- ["zebra", "apple", "mango"], do: {:ok, _} = Store.save(name, sample())
      File.write!(Path.join(Store.dir(), "notes.txt"), "not a sketch")

      assert Store.list() == ["apple", "mango", "zebra"]
    end

    test "listing an absent directory is empty, not an error" do
      assert Store.list() == []
    end

    test "delete removes the file and is fine when there is nothing to remove" do
      {:ok, _} = Store.save("plan", sample())

      assert :ok = Store.delete("plan")
      assert Store.list() == []
      assert :ok = Store.delete("plan")
    end
  end

  describe "writing is atomic" do
    test "no temporary file is left behind on success" do
      # The drawing is the only copy — there is no database behind it — so a
      # crash mid-write must leave the previous sketch rather than a truncated one.
      {:ok, _} = Store.save("plan", sample())

      assert Store.dir() |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".tmp")) == []
    end
  end

  describe "every kind round-trips" do
    # The guard for the bug that shipped inside this session: `element_to_map/1`
    # was flat (points/colour/width) and adding `:image` did not touch it, so an
    # image was written with none of its fields and refused on the next load —
    # then DROPPED silently by the very rule that protects a sketch from one bad
    # element. The drawing just had no picture in it.
    #
    # Driven off `Element.kinds()` rather than a hand-written list, so a kind
    # added in a later phase fails here until the serializer learns it.
    @samples %{
      stroke: %{
        "kind" => "stroke",
        "points" => [[1, 2], [3, 4]],
        "color" => "#1C9BFF",
        "width" => 6
      },
      image: %{
        "kind" => "image",
        "source" => "0123456789abcdef.png",
        "x" => 12,
        "y" => 34,
        "w" => 56,
        "h" => 78
      }
    }

    test "there is a sample for every kind that exists" do
      assert Enum.sort(Map.keys(@samples)) == Enum.sort(Element.kinds()),
             "a kind was added without a round-trip sample — the serializer is probably " <>
               "unaware of it too, and its elements will vanish on the next load"
    end

    test "saving and loading preserves every field of every kind" do
      elements =
        Enum.map(Element.kinds(), fn kind ->
          {:ok, element} = @samples |> Map.fetch!(kind) |> Element.new()
          element
        end)

      doc = Enum.reduce(elements, Document.new(), &Document.add(&2, &1))
      {:ok, _} = Store.save("every-kind", doc)

      assert {:ok, loaded} = Store.load("every-kind")

      assert Document.size(loaded) == length(elements),
             "an element was dropped on load — its fields did not survive the write"

      for {before, after_load} <- Enum.zip(elements, loaded.elements) do
        assert before.id == after_load.id
        assert before.kind == after_load.kind
        assert before.author == after_load.author

        # Every populated field, whatever the kind. A serializer that forgets one
        # produces an element that loads with a hole rather than an error.
        for field <- [:points, :color, :width, :source, :x, :y, :w, :h] do
          assert Map.get(before, field) == Map.get(after_load, field),
                 "#{before.kind}.#{field} did not survive the round trip"
        end
      end
    end
  end
end
