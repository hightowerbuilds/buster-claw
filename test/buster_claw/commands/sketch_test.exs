defmodule BusterClaw.Commands.SketchTest do
  # Phase 2 — the model can READ a sketch. Phase 3 — it can DRAW on one, bounded
  # by `D6`: it may change and delete what it made, and an operator's mark is
  # gated rather than obeyed.
  use ExUnit.Case, async: false

  alias BusterClaw.Commands
  alias BusterClaw.Commands.Sketch, as: SketchCmd
  alias BusterClaw.Sketch.{Assets, Document, Element, Store}

  # The model's caller. `:agent` is what an MCP-token agent carries, and the
  # dispatcher refuses it anything `:restricted` — so the authorship rule is
  # exercised against the module that owns it, where the tier check cannot mask
  # it. "the dispatcher carries the caller" below covers that seam separately.
  @model :agent

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

  defp text!(overrides) do
    {:ok, element} =
      Map.merge(
        %{
          "kind" => "text",
          "content" => "label",
          "color" => "#F4F1EA",
          "size" => 18,
          "x" => 40,
          "y" => 50
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

  # Wire-shaped args for the write verbs, so a test can override one field
  # without restating the other six.
  defp text_args(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "plan",
        "kind" => "text",
        "content" => "hello",
        "color" => "#F4F1EA",
        "size" => 18,
        "x" => 10,
        "y" => 20
      },
      overrides
    )
  end

  defp stroke_args(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "plan",
        "kind" => "stroke",
        "points" => [[0, 0], [10, 10]],
        "color" => "#FF4D1C",
        "width" => 2
      },
      overrides
    )
  end

  defp sketch_commands do
    Enum.filter(Commands.list_commands(), &String.starts_with?(&1.name, "sketch"))
  end

  defp command!(name) do
    Enum.find(sketch_commands(), &(&1.name == name)) ||
      flunk("#{name} is not in the catalog")
  end

  describe "the surface: two reads, four writes, and one gate" do
    # This replaced a test asserting that NO sketch command mutates. That was
    # true in Phase 2 and false the day Phase 3 landed, and a guard whose only
    # content is "the feature does not exist yet" retires with the phase it
    # belonged to. What is worth pinning instead is the SHAPE of the write half
    # — which verbs exist, what tier each carries, which one is gated. Every
    # line below is a change to the trust boundary if it moves.
    @reads ~w(sketch_list sketch_get)
    @writes ~w(sketch_create sketch_add sketch_update sketch_delete)

    test "the family is exactly these six" do
      assert Enum.sort(Enum.map(sketch_commands(), & &1.name)) == Enum.sort(@reads ++ @writes)
    end

    test "the reads stay safe" do
      for name <- @reads do
        command = command!(name)

        assert command.type == :read, "#{name} is #{command.type}"
        assert command.tier == :safe, "#{name} is #{command.tier}"
        refute Map.get(command, :gated, false), "#{name} is gated — a read is not irreversible"
      end
    end

    test "every write is restricted" do
      for name <- @writes do
        command = command!(name)

        assert command.type == :mutate, "#{name} is #{command.type}"

        assert command.tier == :restricted,
               "#{name} is #{command.tier} — a write into the operator's drawing is never :safe"
      end
    end

    test "no sketch command is gated, and that is deliberate" do
      # RESOLVED 08-16, against the instinct. `sketch_delete` carried `gated:
      # true` for an afternoon — matching twelve of fourteen `*_delete` entries
      # — and the flag made the feature impossible: `gated` is refused to
      # `:agent_untrusted` by the PolicyEngine baseline, and `:agent_untrusted`
      # is the ONLY caller both allowed a `:restricted` command and treated as
      # the model by `Authorship`. No caller could delete its own mark.
      #
      # `gated` is a statement about a VERB; `D6` is a statement about the DATA,
      # and here the data-level rule strictly dominates: an operator's element
      # is refused and surfaced for approval (everything the gate would have
      # achieved) while the model's own false starts stay free to remove (which
      # the gate made impossible). A blanket gate was the weaker protection
      # wearing the stronger word.
      gated = for command <- sketch_commands(), Map.get(command, :gated, false), do: command.name

      assert gated == [],
             "a gate here would stop the model removing its OWN marks — see D6"
    end

    test "the catalog and the dispatcher agree", %{id: id} do
      # A catalog entry with no function behind it answers `unknown_command` at
      # runtime and nothing else notices. Run as `:trusted`: three of the six
      # are `:restricted` and one is gated, so a lesser caller would be stopped
      # by policy before dispatch happened — which is not what this checks.
      for command <- sketch_commands() do
        result = Commands.call(command.name, args_for(command.name, id), caller: :trusted)

        assert match?({:ok, _}, result), "#{command.name} did not dispatch: #{inspect(result)}"
      end
    end

    defp args_for("sketch_get", _id), do: %{"name" => "seeded", "preview" => false}
    defp args_for("sketch_create", _id), do: %{"name" => "fresh"}
    defp args_for("sketch_add", _id), do: text_args(%{"name" => "seeded"})
    defp args_for("sketch_update", id), do: %{"name" => "seeded", "id" => id, "dx" => 3}
    defp args_for("sketch_delete", id), do: %{"name" => "seeded", "id" => id}
    defp args_for(_name, _id), do: %{}

    setup do
      doc = seed("seeded", [stroke!()])
      %{id: hd(doc.elements).id}
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
      # on — the write half moves and deletes whole elements, it does not edit
      # vertices — so dumping them would spend most of the reply on noise.
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

    test "a label carries its words and its anchor, and no box it cannot measure" do
      # `:text` was a kind `Element` accepted and nothing could create, so
      # `sketch_get` had no clause for one — it would have raised on the first
      # label `sketch_add` wrote. A label is sized by the renderer measuring its
      # own glyphs, so it reports `at` rather than a `bounds` it would have to
      # invent.
      seed("plan", [text!(%{"content" => "north wall"})])

      assert {:ok, %{elements: [element]}} =
               Commands.call("sketch_get", %{"name" => "plan", "preview" => false},
                 caller: :agent
               )

      assert element.kind == "text"
      assert element.content == "north wall"
      assert element.size == 18
      assert element.at == %{x: 40.0, y: 50.0}
      refute Map.has_key?(element, :bounds)
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

  describe "sketch_create" do
    test "makes an empty sketch the other verbs can address" do
      assert {:ok, %{name: "plan", count: 0}} =
               SketchCmd.sketch_create(%{"name" => "plan", "title" => "Kitchen"})

      assert {:ok, doc} = Store.load("plan")
      assert doc.title == "Kitchen"
      assert Document.size(doc) == 0
    end

    test "the title defaults to the name" do
      {:ok, _} = SketchCmd.sketch_create(%{"name" => "plan"})

      assert {:ok, %{title: "plan"}} = Store.load("plan")
    end

    test "it refuses rather than truncating a sketch that is already there" do
      # `Store.save/2` is a blind overwrite — it has to be, since every other
      # write goes through it. A create that silently emptied a drawing is the
      # one unrecoverable mistake on this surface: the file is the only copy.
      seed("plan", [stroke!()])

      assert {:error, :already_exists} = SketchCmd.sketch_create(%{"name" => "plan"})

      assert {:ok, doc} = Store.load("plan")
      assert Document.size(doc) == 1
    end

    test "a name shaped like a path is refused before the filesystem is touched" do
      assert {:error, :invalid_name} = SketchCmd.sketch_create(%{"name" => "../../etc/passwd"})
    end

    test "a name is required" do
      assert {:error, :missing_name} = SketchCmd.sketch_create(%{})
    end
  end

  describe "sketch_add" do
    setup do
      seed("plan", [])
      :ok
    end

    test "a model's mark is stamped :model and given an app-minted id" do
      assert {:ok, added} = SketchCmd.sketch_add(text_args(), @model)

      assert added.author == "model"
      assert added.kind == "text"
      assert String.starts_with?(added.id, "el_")
      assert added.count == 1
    end

    test "a model-supplied id and author are ignored, not honoured" do
      # Both are what `D6` rests on. A caller-chosen id would let a writer
      # address an element it does not own by guessing one; a caller-chosen
      # author would let it simply declare the operator's marks its own.
      args = Map.merge(text_args(), %{"id" => "el_stolen", "author" => "operator"})

      assert {:ok, added} = SketchCmd.sketch_add(args, @model)
      assert added.id != "el_stolen"
      assert added.author == "model"

      {:ok, doc} = Store.load("plan")
      assert [%Element{author: :model}] = doc.elements
      refute Document.find(doc, "el_stolen")
    end

    test "the operator's own hand is stamped :operator" do
      assert {:ok, %{author: "operator"}} = SketchCmd.sketch_add(text_args(), :trusted)
      assert {:ok, %{author: "operator"}} = SketchCmd.sketch_add(text_args(), :terminal)
    end

    test "it appends — list order is paint order" do
      {:ok, first} = SketchCmd.sketch_add(text_args(%{"content" => "one"}), @model)
      {:ok, second} = SketchCmd.sketch_add(text_args(%{"content" => "two"}), @model)

      {:ok, doc} = Store.load("plan")
      assert Enum.map(doc.elements, & &1.id) == [first.id, second.id]
    end

    test "the mark survives a reload" do
      {:ok, added} = SketchCmd.sketch_add(stroke_args(), @model)

      assert {:ok, doc} = Store.load("plan")
      assert %Element{kind: :stroke, author: :model} = element = Document.find(doc, added.id)
      assert element.points == [[0.0, 0.0], [10.0, 10.0]]
    end

    test "a field that fails validation refuses the whole call" do
      assert {:error, {:bad_color, "red"}} =
               SketchCmd.sketch_add(text_args(%{"color" => "red"}), @model)

      assert {:error, {:unknown_kind, "sphere"}} =
               SketchCmd.sketch_add(text_args(%{"kind" => "sphere"}), @model)

      assert {:ok, doc} = Store.load("plan")
      assert Document.size(doc) == 0, "a refused add must leave the drawing alone"
    end

    test "an unknown sketch is not found, and a bad name is refused" do
      assert {:error, :not_found} = SketchCmd.sketch_add(text_args(%{"name" => "nope"}), @model)

      assert {:error, :invalid_name} =
               SketchCmd.sketch_add(text_args(%{"name" => "../etc/passwd"}), @model)
    end

    test "a name is required" do
      assert {:error, :missing_name} = SketchCmd.sketch_add(%{"kind" => "text"}, @model)
    end
  end

  describe "D6 — the model may touch what the model made, and nothing else" do
    setup do
      doc = seed("plan", [stroke!(), stroke!(%{"author" => "model"})])

      %{operator: hd(doc.elements).id, model: List.last(doc.elements).id}
    end

    test "a model changes and removes its own mark", %{model: id} do
      assert {:ok, _} =
               SketchCmd.sketch_update(
                 %{"name" => "plan", "id" => id, "dx" => 5, "dy" => -5},
                 @model
               )

      assert {:ok, %{deleted: true, count: 1}} =
               SketchCmd.sketch_delete(%{"name" => "plan", "id" => id}, @model)

      {:ok, doc} = Store.load("plan")
      refute Document.find(doc, id)
    end

    test "a model may not change the operator's mark", %{operator: id} do
      assert {:error, :requires_confirmation} =
               SketchCmd.sketch_update(%{"name" => "plan", "id" => id, "dx" => 5}, @model)

      {:ok, doc} = Store.load("plan")
      element = Document.find(doc, id)

      assert element, "the operator's stroke must still be there"
      assert element.points == [[10.0, 20.0], [110.0, 220.0]], "and must not have moved"
    end

    test "a model may not delete the operator's mark", %{operator: id} do
      # The Cleo failure mode — an agent removing the user's work because it
      # conflicts with its own plan — refused structurally rather than prompted
      # against.
      assert {:error, :requires_confirmation} =
               SketchCmd.sketch_delete(%{"name" => "plan", "id" => id}, @model)

      {:ok, doc} = Store.load("plan")
      assert Document.find(doc, id)
      assert Document.size(doc) == 2
    end

    test "authorship is checked before the change is even validated", %{operator: id} do
      # The refusal must be about WHOSE mark it is, not about the args. If a
      # bad colour were caught first, the model would learn the element exists
      # and is editable, and would keep trying.
      assert {:error, :requires_confirmation} =
               SketchCmd.sketch_update(
                 %{"name" => "plan", "id" => id, "color" => "not a colour"},
                 @model
               )
    end

    test "a trusted caller owns every mark, including the model's", %{
      operator: operator,
      model: model
    } do
      assert {:ok, _} =
               SketchCmd.sketch_update(%{"name" => "plan", "id" => operator, "dx" => 5}, :trusted)

      assert {:ok, %{deleted: true}} =
               SketchCmd.sketch_delete(%{"name" => "plan", "id" => operator}, :trusted)

      assert {:ok, %{deleted: true}} =
               SketchCmd.sketch_delete(%{"name" => "plan", "id" => model}, :trusted)

      {:ok, doc} = Store.load("plan")
      assert Document.size(doc) == 0
    end

    test "the terminal is the operator's own shell and is treated as one", %{operator: id} do
      assert {:ok, %{deleted: true}} =
               SketchCmd.sketch_delete(%{"name" => "plan", "id" => id}, :terminal)
    end

    test "an unknown id is refused BY NAME, never silently skipped" do
      # `D5`. A delete answering `{:ok, deleted: true}` for an id that was never
      # there is the failure that cannot be diagnosed from outside — and the
      # model is the one holding these ids now.
      assert {:error, :not_found} =
               SketchCmd.sketch_delete(%{"name" => "plan", "id" => "el_nope"}, @model)

      assert {:error, :not_found} =
               SketchCmd.sketch_update(%{"name" => "plan", "id" => "el_nope", "dx" => 1}, @model)

      assert {:error, :not_found} =
               SketchCmd.sketch_update(
                 %{"name" => "plan", "id" => "el_nope", "content" => "x"},
                 :trusted
               )

      {:ok, doc} = Store.load("plan")
      assert Document.size(doc) == 2
    end
  end

  describe "sketch_update" do
    test "a move translates that element and leaves the others alone" do
      doc = seed("plan", [stroke!(%{"author" => "model"}), stroke!(%{"author" => "model"})])
      [moved, still] = doc.elements

      assert {:ok, _} =
               SketchCmd.sketch_update(
                 %{"name" => "plan", "id" => moved.id, "dx" => 5, "dy" => -2},
                 @model
               )

      {:ok, reloaded} = Store.load("plan")
      assert Document.find(reloaded, moved.id).points == [[15.0, 18.0], [115.0, 218.0]]
      assert Document.find(reloaded, still.id).points == still.points
    end

    test "one axis may be given on its own" do
      doc = seed("plan", [stroke!(%{"author" => "model"})])
      [element] = doc.elements

      assert {:ok, _} =
               SketchCmd.sketch_update(
                 %{"name" => "plan", "id" => element.id, "dy" => 10},
                 @model
               )

      {:ok, reloaded} = Store.load("plan")
      assert Document.find(reloaded, element.id).points == [[10.0, 30.0], [110.0, 230.0]]
    end

    test "a label moves, and moves by the same delta a stroke would" do
      # This asserted `:not_movable` for one afternoon, and it was right to at
      # the time: `Document.move/3` translated a stroke's `points` and handed
      # every other kind back UNCHANGED with `{:ok, doc}` — telling a model its
      # label had moved when nothing had, which is `D5`'s failure reached from
      # the inside. The command detected it by comparing before and after.
      #
      # That was a workaround for an answer the wrong layer was giving. `move/3`
      # knows how each kind stores its position and now translates `x`/`y` too,
      # so the comparison is gone and this asserts the behaviour rather than the
      # apology for it.
      doc = seed("plan", [text!(%{"author" => "model"})])
      [label] = doc.elements

      assert {:ok, _} =
               SketchCmd.sketch_update(
                 %{"name" => "plan", "id" => label.id, "dx" => 30, "dy" => -5},
                 @model
               )

      {:ok, reloaded} = Store.load("plan")
      moved = Document.find(reloaded, label.id)

      assert moved.x == label.x + 30
      assert moved.y == label.y - 5
    end

    test "a text change crosses the same validation a brand new label does" do
      doc = seed("plan", [text!(%{"author" => "model"})])
      [label] = doc.elements
      args = %{"name" => "plan", "id" => label.id}

      assert {:error, {:bad_color, "chartreuse"}} =
               SketchCmd.sketch_update(Map.put(args, "color", "chartreuse"), @model)

      assert {:error, {:bad_size, 13}} =
               SketchCmd.sketch_update(Map.put(args, "size", 13), @model)

      assert {:error, :empty_content} =
               SketchCmd.sketch_update(Map.put(args, "content", "   "), @model)

      {:ok, reloaded} = Store.load("plan")
      assert Document.find(reloaded, label.id).content == label.content
    end

    test "a text change keeps the id, the author and the creation time" do
      doc = seed("plan", [text!(%{"author" => "model"})])
      [label] = doc.elements

      assert {:ok, _} =
               SketchCmd.sketch_update(
                 %{"name" => "plan", "id" => label.id, "content" => "fixed", "size" => 28},
                 @model
               )

      {:ok, reloaded} = Store.load("plan")
      updated = Document.find(reloaded, label.id)

      assert updated.content == "fixed"
      assert updated.size == 28
      assert updated.color == label.color, "a field not asked about must not move"
      assert updated.author == :model, "an edit is not a change of hands"
      assert DateTime.compare(updated.created_at, label.created_at) == :eq
    end

    test "an edit does not raise the element it edited" do
      # `Document.add/2` appends, so editing by delete-then-add would silently
      # lift the edited mark above everything drawn after it. List order is
      # z-order, and an edit is not a raise.
      doc = seed("plan", [text!(%{"author" => "model"}), stroke!(%{"author" => "model"})])
      [label, stroke] = doc.elements

      assert {:ok, _} =
               SketchCmd.sketch_update(
                 %{"name" => "plan", "id" => label.id, "color" => "#FF4D1C"},
                 @model
               )

      {:ok, reloaded} = Store.load("plan")
      assert Enum.map(reloaded.elements, & &1.id) == [label.id, stroke.id]
    end

    test "retexting something that is not text is refused" do
      doc = seed("plan", [stroke!(%{"author" => "model"})])
      [element] = doc.elements

      assert {:error, :not_text} =
               SketchCmd.sketch_update(
                 %{"name" => "plan", "id" => element.id, "content" => "hi"},
                 @model
               )
    end

    test "asking for no change at all is refused rather than saved as a no-op" do
      doc = seed("plan", [stroke!(%{"author" => "model"})])
      [element] = doc.elements

      assert {:error, :no_change} =
               SketchCmd.sketch_update(%{"name" => "plan", "id" => element.id}, @model)
    end

    test "a delta that is not a number is named rather than ignored" do
      doc = seed("plan", [stroke!(%{"author" => "model"})])
      [element] = doc.elements

      assert {:error, :bad_delta} =
               SketchCmd.sketch_update(
                 %{"name" => "plan", "id" => element.id, "dx" => "5"},
                 @model
               )
    end

    test "name and id are both required" do
      assert {:error, :missing_name_or_id} = SketchCmd.sketch_update(%{"name" => "plan"}, @model)
      assert {:error, :missing_name_or_id} = SketchCmd.sketch_delete(%{"id" => "el_x"}, @model)
      assert {:error, :missing_name_or_id} = SketchCmd.sketch_delete(%{"name" => "plan"}, @model)
    end
  end

  describe "the dispatcher carries the caller, and policy still decides who may write" do
    setup do
      seed("plan", [])
      :ok
    end

    test "the caller reaches the command, and is not read out of args" do
      # `args` is the model's own input. If the caller were a field in it, a
      # model could write `"caller" => "trusted"` and own the operator's marks.
      assert {:ok, %{author: "model"}} =
               Commands.call("sketch_add", text_args(), caller: :agent_untrusted)

      assert {:ok, %{author: "operator"}} =
               Commands.call("sketch_add", text_args(), caller: :trusted)

      assert {:ok, %{author: "model"}} =
               Commands.call("sketch_add", text_args(%{"caller" => "trusted"}),
                 caller: :agent_untrusted
               )
    end

    test "a safe-tier caller may read a sketch but may not write to one" do
      # The whole point of `:safe` — an agent with the narrowest token can look
      # at what the operator drew without being able to change it.
      for caller <- [:agent, :mcp] do
        assert {:ok, _} = Commands.call("sketch_list", %{}, caller: caller)

        assert {:error, :requires_confirmation} =
                 Commands.call("sketch_add", text_args(), caller: caller)

        assert {:error, :requires_confirmation} =
                 Commands.call("sketch_create", %{"name" => "new"}, caller: caller)
      end

      assert Store.list() == ["plan"]
    end

    test "an untrusted-origin run CAN remove its own mark, and only its own" do
      # The other side of the same decision. Both halves are asserted together
      # so neither can be changed without the other being read.
      doc = seed("plan", [stroke!(%{"author" => "model"}), stroke!(%{"author" => "operator"})])
      [mine, theirs] = doc.elements

      assert {:ok, _} =
               Commands.call("sketch_delete", %{"name" => "plan", "id" => mine.id},
                 caller: :agent_untrusted
               )

      assert {:error, :requires_confirmation} =
               Commands.call("sketch_delete", %{"name" => "plan", "id" => theirs.id},
                 caller: :agent_untrusted
               )

      {:ok, reloaded} = Store.load("plan")
      refute Document.find(reloaded, mine.id), "the model could not remove its own false start"
      assert Document.find(reloaded, theirs.id), "the operator's mark was removed"
    end
  end

  describe "the write surface cannot remove a drawing" do
    test "no sketch command reaches the file remover" do
      # `D9`: a sketch is a file the operator owns, and removing one is their
      # act. `sketch_delete` removes an ELEMENT. The absence of a whole-sketch
      # verb is the enforcement, and this import check is what keeps it — a
      # future verb cannot start calling `Store.delete/1` without this test
      # changing in a diff someone has to justify.
      calls = imports(BusterClaw.Commands.Sketch)

      assert calls != [], "the import walk found nothing; it is not walking"
      refute {BusterClaw.Sketch.Store, :delete, 1} in calls
      refute {BusterClaw.Sketch.Assets, :delete_all, 1} in calls
    end

    test "BusterClaw.Commands exports exactly six sketch verbs" do
      # `call/3` dispatches with `apply/3` against that module, so a function
      # there is reachable whether or not it is catalogued.
      exported =
        BusterClaw.Commands.__info__(:functions)
        |> Enum.map(fn {name, _arity} -> Atom.to_string(name) end)
        |> Enum.filter(&String.starts_with?(&1, "sketch"))
        |> Enum.uniq()
        |> Enum.sort()

      assert exported == ~w(sketch_add sketch_create sketch_delete sketch_get sketch_list
               sketch_update)
    end
  end

  defp imports(module) do
    with path when is_list(path) <- :code.which(module),
         {:ok, {_module, [imports: imports]}} <- :beam_lib.chunks(path, [:imports]) do
      imports
    else
      _ -> []
    end
  end
end
