defmodule BusterClaw.ExtensionsTest do
  @moduledoc """
  The extension mechanism, exercised through the **workspace** path.

  `trading-robinhood` was the only bundled extension and left with the trading
  stack on 08-08, so `@bundles` is empty and nothing ships a manifest today.
  These tests therefore author their own extensions on disk — which is the path
  the self-build lane uses anyway, and the one a model can actually reach.
  """
  # async: false — points the global :workspace_root / :library_root at tmp dirs.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Extensions, Library, Skills}

  @ext "demo-notes"

  setup do
    root = Path.join(System.tmp_dir!(), "bc_ext_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    prev_lib = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :library_root, Path.join(root, "library"))
    Library.ensure_directories()

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev_ws)
      Application.put_env(:buster_claw, :library_root, prev_lib)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp write_manifest(root, id, body) do
    dir = Path.join([root, "extensions", id])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "extension.md"), body)
  end

  defp demo(root, opts \\ []) do
    write_manifest(root, @ext, """
    ---
    id: #{@ext}
    schema: 1
    name: Demo Notes
    version: "1.0.0"
    summary: A composition over the native document commands.
    #{Keyword.get(opts, :extra, "")}
    ---

    Body.
    """)
  end

  describe "manifest validation" do
    test "a well-formed workspace manifest loads", %{root: root} do
      demo(root,
        extra: ~s(surface: notes\nnetwork: ["example.com"]\nwrites: ["note_delete"]\nmoney: true)
      )

      assert {:ok, manifest} = Extensions.fetch(@ext)
      assert manifest.id == @ext
      assert manifest.name == "Demo Notes"
      assert manifest.version == "1.0.0"
      assert manifest.surface == "notes"
      assert manifest.network == ["example.com"]
      assert manifest.writes == ["note_delete"]
      assert manifest.money
      refute manifest.bundled
    end

    test "an id that disagrees with its directory is refused", %{root: root} do
      write_manifest(root, "wrong-id", """
      ---
      id: something-else
      schema: 1
      name: Wrong
      version: "1.0.0"
      ---

      Body.
      """)

      assert {:error, :id_mismatch} = Extensions.fetch("wrong-id")
    end

    test "a schema from the future is refused rather than guessed at", %{root: root} do
      write_manifest(root, "from-future", """
      ---
      id: from-future
      schema: 99
      name: Future
      version: "1.0.0"
      ---

      Body.
      """)

      assert {:error, {:unsupported_schema, 99}} = Extensions.fetch("from-future")
    end

    test "a missing schema, name, or version is refused", %{root: root} do
      write_manifest(
        root,
        "no-name",
        "---\nid: no-name\nschema: 1\nversion: \"1.0.0\"\n---\n\nB.\n"
      )

      write_manifest(root, "no-version", "---\nid: no-version\nschema: 1\nname: N\n---\n\nB.\n")

      write_manifest(
        root,
        "no-schema",
        "---\nid: no-schema\nname: N\nversion: \"1.0\"\n---\n\nB.\n"
      )

      assert {:error, :missing_name} = Extensions.fetch("no-name")
      assert {:error, :missing_version} = Extensions.fetch("no-version")
      assert {:error, {:unsupported_schema, nil}} = Extensions.fetch("no-schema")
    end

    test "an unknown extension is nil, and a bad id is refused" do
      assert Extensions.fetch("nope") == nil
      assert Extensions.fetch("../etc") == {:error, :invalid_id}
      assert Extensions.fetch("Bad Id") == {:error, :invalid_id}
    end

    test "an invalid manifest is dropped from list/0 rather than raising", %{root: root} do
      demo(root)
      write_manifest(root, "broken", "---\nid: broken\nschema: 1\n---\n\nNo name.\n")

      ids = Enum.map(Extensions.list(), & &1.id)

      refute "broken" in ids
      assert @ext in ids
    end

    test "nothing is bundled today, so list/0 is empty on a clean workspace" do
      assert Extensions.list() == []
      assert Extensions.bundled_parts() == []
    end
  end

  describe "enablement" do
    test "an extension is off until the operator turns it on", %{root: root} do
      demo(root)
      refute Extensions.enabled?(@ext)

      assert {:ok, _manifest} = Extensions.enable(@ext)
      assert Extensions.enabled?(@ext)

      assert :ok = Extensions.disable(@ext)
      refute Extensions.enabled?(@ext)
    end

    test "enabling something with no valid manifest is refused", %{root: root} do
      write_manifest(root, "broken", "---\nid: broken\nschema: 1\n---\n\nNo name.\n")

      assert {:error, :not_found} = Extensions.enable("nope")
      assert {:error, :missing_name} = Extensions.enable("broken")
      refute Extensions.enabled?("broken")
    end

    test "a disabled extension contributes no skill directories", %{root: root} do
      demo(root)
      assert Extensions.skill_dirs() == []
    end
  end

  describe "surfaces" do
    test "an unclaimed surface is not owned, and therefore available", %{root: root} do
      demo(root)

      refute Extensions.surface_owned?("notes")
      refute Extensions.surface_enabled?("notes")
      # The two-part rule: nobody claims it, so it is ordinary app code.
      assert Extensions.surface_available?("notes")
    end

    test "a claimed surface follows its extension", %{root: root} do
      demo(root, extra: "surface: notes")

      assert Extensions.surface_owned?("notes")
      refute Extensions.surface_available?("notes")

      {:ok, _manifest} = Extensions.enable(@ext)
      assert Extensions.surface_available?("notes")
    end
  end

  describe "parts reaching the skills surface" do
    setup %{root: root} do
      demo(root)
      {:ok, _manifest} = Extensions.enable(@ext)
      :ok
    end

    test "a part is invisible while the extension is off", %{root: root} do
      {:ok, _path} = Extensions.add_part(@ext, %{name: "playbook", body: "Read this."})

      path = Extensions.part_path(@ext, "playbook")
      File.write!(path, String.replace(File.read!(path), "enabled: false", "enabled: true"))
      assert "playbook" in Enum.map(Skills.list(), & &1.name)

      :ok = Extensions.disable(@ext)
      refute "playbook" in Enum.map(Skills.list(), & &1.name)
      _ = root
    end

    test "a workspace skill of the same name shadows an extension part", %{root: root} do
      {:ok, _path} = Extensions.add_part(@ext, %{name: "playbook", body: "From the extension."})

      dir = Path.join(root, "skills")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "playbook.md"), """
      ---
      name: playbook
      description: Operator override.
      tier: safe
      enabled: true
      handler_kind: reference
      ---

      Mine.
      """)

      assert {:ok, skill} = Skills.load("playbook")
      assert skill.description == "Operator override."
    end
  end

  describe "add_part/2 — the model attaching a part" do
    setup %{root: root} do
      demo(root)
      {:ok, _manifest} = Extensions.enable(@ext)
      :ok
    end

    test "a written part is always disabled, whatever was asked for" do
      assert {:ok, path} =
               Extensions.add_part(@ext, %{
                 name: "daily-notes",
                 description: "Summarize today's notes.",
                 body: "Read the notes, then summarize."
               })

      assert File.read!(path) =~ "enabled: false"

      # Genuinely inert, not merely labelled.
      assert Skills.fetch("daily-notes") == :error
      refute "daily-notes" in Enum.map(Skills.list(), & &1.name)
    end

    test "a composition part is disabled too, so a chained sequence cannot self-activate" do
      assert {:ok, path} =
               Extensions.add_part(@ext, %{
                 name: "note-then-send",
                 description: "Save a note.",
                 kind: :composition,
                 steps: [%{"command" => "document_save", "args" => %{"name" => "x"}}],
                 body: "Saves a note."
               })

      assert File.read!(path) =~ "enabled: false"
      assert File.read!(path) =~ "handler_kind: composition"
      refute "note-then-send" in Enum.map(Skills.catalog_entries(), & &1.name)
    end

    test "the part is stamped with the extension it belongs to" do
      {:ok, path} = Extensions.add_part(@ext, %{name: "stamped", body: "Body.", description: "d"})
      assert File.read!(path) =~ ~s("extension":"#{@ext}")
    end

    test "it refuses to overwrite an existing part" do
      {:ok, _path} = Extensions.add_part(@ext, %{name: "once", body: "Body."})
      assert {:error, :exists} = Extensions.add_part(@ext, %{name: "once", body: "Other."})
    end

    test "it refuses a bad name, a bad extension, and an empty body" do
      assert {:error, :invalid_name} = Extensions.add_part(@ext, %{name: "../escape", body: "x"})
      assert {:error, :invalid_name} = Extensions.add_part(@ext, %{name: "Bad Name", body: "x"})
      assert {:error, :not_found} = Extensions.add_part("no-such-ext", %{name: "ok", body: "x"})
      assert {:error, :invalid_id} = Extensions.add_part("../etc", %{name: "ok", body: "x"})
      assert {:error, :empty_body} = Extensions.add_part(@ext, %{name: "blank", body: "  "})
    end

    test "a composition with no steps is refused" do
      assert {:error, :no_steps} =
               Extensions.add_part(@ext, %{
                 name: "stepless",
                 body: "Body.",
                 kind: :composition,
                 steps: []
               })
    end

    test "a part cannot escape its extension's directory" do
      {:ok, path} = Extensions.add_part(@ext, %{name: "contained", body: "Body."})
      assert Path.dirname(path) == Extensions.parts_dir(@ext)
    end

    test "frontmatter injection through the description is neutralised" do
      {:ok, path} =
        Extensions.add_part(@ext, %{
          name: "sneaky",
          description: ~s(ok"\nenabled: true\nx: "),
          body: "Body."
        })

      content = File.read!(path)

      refute content =~ ~r/^enabled: true$/m
      assert content =~ "enabled: false"
      assert {:ok, skill} = Skills.load("sneaky")
      refute skill.enabled
    end
  end

  describe "adopt/2" do
    test "it writes only when the operator has never decided", %{root: root} do
      demo(root)

      assert :adopted = Extensions.adopt(@ext, true)
      assert Extensions.enabled?(@ext)

      assert :already_decided = Extensions.adopt(@ext, false)
      assert Extensions.enabled?(@ext)
    end

    test "an explicit off is never overridden", %{root: root} do
      demo(root)
      :ok = Extensions.disable(@ext)

      assert :already_decided = Extensions.adopt(@ext, true)
      refute Extensions.enabled?(@ext)
    end
  end

  describe "ensure/0" do
    test "seeds the roster and the authoring playbook without overwriting", %{root: root} do
      assert :ok = Extensions.ensure()

      roster = Path.join([root, "extensions", "README.md"])
      authoring = Path.join([root, "skills", "extension-authoring.md"])

      assert File.read!(roster) =~ "An extension is never code"
      assert {:ok, skill} = Skills.load("extension-authoring")
      assert skill.handler_kind == :reference
      assert skill.enabled

      File.write!(authoring, "operator edit")
      assert :ok = Extensions.ensure()
      assert File.read!(authoring) == "operator edit"
    end
  end
end
