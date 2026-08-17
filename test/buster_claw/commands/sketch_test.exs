defmodule BusterClaw.Commands.SketchTest do
  # Phase 2 — the model can READ a sketch. The write half is Phase 3, and the
  # absence of it is asserted here rather than merely intended.
  use ExUnit.Case, async: false

  alias BusterClaw.Commands
  alias BusterClaw.Sketch.{Assets, Document, Element, Store}

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAAC56t6BAAAAFElEQVR4nGP8" <>
           "z8Dwn4GBgYEJRAAAHAAD/1a0lqcAAAAASUVORK5CYII="
       )

  setup do
    root = Path.join(System.tmp_dir!(), "bc_sketchcmd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    :ok
  end

  defp stroke!(overrides \\ %{}) do
    {:ok, element} =
      Map.merge(
        %{
          "kind" => "stroke",
          "points" => [[10, 20], [110, 220]],
          "color" => "#FF4D1C",
          "width" => 2
        },
        overrides
      )
      |> Element.new()

    element
  end

  defp seed(name, elements) do
    doc = Enum.reduce(elements, Document.new(%{title: name}), &Document.add(&2, &1))
    {:ok, _} = Store.save(name, doc)
    doc
  end

  describe "the surface is read-only, and that is the phase" do
    # The same shape as the guard that keeps a mutating verb out of Pockets.
    # Phase 3 adds the write half behind D6; until then a verb that changes a
    # sketch must not exist at any tier.
    test "no sketch command mutates" do
      sketch_commands =
        Enum.filter(Commands.list_commands(), &String.starts_with?(&1.name, "sketch"))

      assert sketch_commands != [], "the sketch commands vanished from the catalog"

      for command <- sketch_commands do
        assert command.type == :read,
               "#{command.name} is #{command.type} — Phase 3 owns the write half, behind D6"

        assert command.tier == :safe
        refute command.name =~ ~r/add|create|update|delete|move|clear|import/
      end
    end

    test "the catalog and the dispatcher agree" do
      # A catalog entry with no function behind it answers `unknown_command` at
      # runtime and nothing else notices.
      for command <-
            Enum.filter(Commands.list_commands(), &String.starts_with?(&1.name, "sketch")) do
        assert {:ok, _} = Commands.call(command.name, args_for(command.name), caller: :agent)
      end
    end

    defp args_for("sketch_get"), do: %{"name" => "seeded", "preview" => false}
    defp args_for(_name), do: %{}

    setup do
      seed("seeded", [stroke!()])
      :ok
    end
  end

  describe "sketch_list" do
    test "reports every sketch with what is on it and who made it" do
      seed("plan", [stroke!(), stroke!(%{"author" => "model"})])
      seed("empty", [])

      assert {:ok, %{sketches: sketches, count: 2}} =
               Commands.call("sketch_list", %{}, caller: :agent)

      plan = Enum.find(sketches, &(&1.name == "plan"))
      assert plan.elements == 2
      assert plan.authors == %{"operator" => 1, "model" => 1}
      assert %DateTime{} = plan.updated_at
    end

    test "an unreadable sketch is reported, not omitted" do
      # A drawing whose file will not parse is one the operator still has.
      # Omitting it would read as "deleted".
      seed("good", [stroke!()])
      File.write!(Path.join(Store.dir(), "broken.json"), "not json")

      assert {:ok, %{sketches: sketches}} = Commands.call("sketch_list", %{}, caller: :agent)

      broken = Enum.find(sketches, &(&1.name == "broken"))
      assert broken.error == "unreadable"
      assert Enum.find(sketches, &(&1.name == "good")).elements == 1
    end
  end

  describe "sketch_get" do
    test "returns every element with the id a later phase will act on" do
      doc = seed("plan", [stroke!(), stroke!(%{"author" => "model"})])

      assert {:ok, got} =
               Commands.call("sketch_get", %{"name" => "plan", "preview" => false},
                 caller: :agent
               )

      assert got.count == 2
      assert Enum.map(got.elements, & &1.id) == Enum.map(doc.elements, & &1.id)
      assert Enum.map(got.elements, & &1.author) == ["operator", "model"]
    end

    test "a stroke carries its shape, not its coordinates" do
      # A freehand mark is hundreds of points that say nothing a model can act
      # on — Phase 3 moves and deletes whole elements, it does not edit vertices
      # — so dumping them would spend most of the reply on noise.
      seed("plan", [stroke!(%{"points" => [[10, 20], [60, 40], [110, 220]]})])

      assert {:ok, %{elements: [element]}} =
               Commands.call("sketch_get", %{"name" => "plan", "preview" => false},
                 caller: :agent
               )

      assert element.points == 3
      assert element.bounds == %{x: 10.0, y: 20.0, w: 100.0, h: 200.0}
      refute Map.has_key?(element, :coordinates)
    end

    test "an image carries its source and its box" do
      {:ok, asset} = Assets.put_binary("plan", @png)

      {:ok, image} =
        Element.new(%{
          "kind" => "image",
          "source" => asset.source,
          "x" => 5,
          "y" => 6,
          "w" => 70,
          "h" => 80
        })

      seed("plan", [image])

      assert {:ok, %{elements: [element]}} =
               Commands.call("sketch_get", %{"name" => "plan", "preview" => false},
                 caller: :agent
               )

      assert element.kind == "image"
      assert element.source == asset.source
      assert element.bounds == %{x: 5.0, y: 6.0, w: 70.0, h: 80.0}
    end

    test "a missing sketch is not found, and a bad name is refused" do
      assert {:error, :not_found} =
               Commands.call("sketch_get", %{"name" => "nope"}, caller: :agent)

      assert {:error, :invalid_name} =
               Commands.call("sketch_get", %{"name" => "../../etc/passwd"}, caller: :agent)
    end

    test "a name is required" do
      assert {:error, :missing_name} = Commands.call("sketch_get", %{}, caller: :agent)
    end
  end

  describe "the preview — D4's other half" do
    test "a rendered picture is offered as a path, never as bytes" do
      # An agent CLI can open a file. A base64 blob in a command result would
      # spend the operator's context on something they did not ask to read.
      seed("plan", [stroke!()])

      assert {:ok, got} = Commands.call("sketch_get", %{"name" => "plan"}, caller: :agent)

      case got do
        %{preview: path} when is_binary(path) ->
          assert File.regular?(path)
          assert Path.extname(path) == ".png"
          refute got.preview =~ "base64"

        %{preview: nil, preview_error: reason} ->
          # Rasterising leans on a macOS thumbnailer. A machine without it must
          # still get the elements — the read is about the drawing, not the
          # picture of it.
          assert reason in ~w(no_renderer render_failed render_timeout unwritable)
      end

      assert got.count == 1, "the elements must be returned whether or not the picture rendered"
    end

    test "preview false skips rendering entirely" do
      seed("plan", [stroke!()])

      assert {:ok, got} =
               Commands.call("sketch_get", %{"name" => "plan", "preview" => false},
                 caller: :agent
               )

      refute Map.has_key?(got, :preview)
    end

    test "an unchanged sketch reuses its render rather than making another" do
      seed("plan", [stroke!()])

      {:ok, first} = Commands.call("sketch_get", %{"name" => "plan"}, caller: :agent)
      {:ok, second} = Commands.call("sketch_get", %{"name" => "plan"}, caller: :agent)

      assert first.preview == second.preview
    end
  end

  describe "trust" do
    test "a safe-tier caller may read a sketch" do
      # The whole point of :safe — an agent with the narrowest token can look at
      # what the operator drew without being able to change it.
      seed("plan", [stroke!()])

      assert {:ok, _} = Commands.call("sketch_list", %{}, caller: :mcp)

      assert {:ok, _} =
               Commands.call("sketch_get", %{"name" => "plan", "preview" => false}, caller: :mcp)
    end
  end
end
