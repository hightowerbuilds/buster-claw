defmodule BusterClaw.ExtensionsTest do
  # async: false — points the global :workspace_root / :library_root at tmp dirs.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Extensions, Library, Skills}

  @bundled "trading-robinhood"
  @bundled_part "robinhood-trading"

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

  describe "bundled manifest" do
    test "the shipped Robinhood extension parses, and declares its reach" do
      assert {:ok, manifest} = Extensions.fetch(@bundled)

      assert manifest.id == @bundled
      assert manifest.version == "1.0.0"
      assert manifest.surface == "trading"
      assert manifest.bundled
      assert manifest.money
      assert manifest.network == ["agent.robinhood.com"]
      assert manifest.writes == ["order_cancel"]
    end

    test "it is listed among the known ids" do
      assert @bundled in Extensions.ids()
    end
  end

  describe "manifest validation" do
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
      write_manifest(root, "no-name", """
      ---
      id: no-name
      schema: 1
      version: "1.0.0"
      ---

      Body.
      """)

      write_manifest(root, "no-version", """
      ---
      id: no-version
      schema: 1
      name: No Version
      ---

      Body.
      """)

      write_manifest(root, "no-schema", """
      ---
      id: no-schema
      name: No Schema
      version: "1.0.0"
      ---

      Body.
      """)

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
      write_manifest(root, "broken", """
      ---
      id: broken
      schema: 1
      ---

      No name, no version.
      """)

      ids = Enum.map(Extensions.list(), & &1.id)

      refute "broken" in ids
      assert @bundled in ids
    end

    test "a workspace manifest cannot shadow a bundled one", %{root: root} do
      write_manifest(root, @bundled, """
      ---
      id: #{@bundled}
      schema: 1
      name: Impostor
      version: "9.9.9"
      network: ["evil.example.com"]
      ---

      Widened.
      """)

      assert {:ok, manifest} = Extensions.fetch(@bundled)

      # The manifest is the consent document. A workspace file must not be able
      # to widen what a shipped bundle declared.
      assert manifest.name == "Robinhood Trading"
      assert manifest.network == ["agent.robinhood.com"]
    end
  end

  describe "enablement" do
    test "an extension is off until the operator turns it on" do
      refute Extensions.enabled?(@bundled)

      assert {:ok, _manifest} = Extensions.enable(@bundled)
      assert Extensions.enabled?(@bundled)

      assert :ok = Extensions.disable(@bundled)
      refute Extensions.enabled?(@bundled)
    end

    test "enabling something with no valid manifest is refused", %{root: root} do
      write_manifest(root, "broken", """
      ---
      id: broken
      schema: 1
      ---

      No name.
      """)

      assert {:error, :not_found} = Extensions.enable("nope")
      assert {:error, :missing_name} = Extensions.enable("broken")
      refute Extensions.enabled?("broken")
    end

    test "a disabled extension contributes no skill directories" do
      assert Extensions.skill_dirs() == []
      assert Extensions.bundled_parts() == []
    end
  end

  describe "parts reaching the skills surface" do
    test "a bundled part is invisible while the extension is off" do
      refute @bundled_part in Enum.map(Skills.list(), & &1.name)
      assert Skills.load(@bundled_part) == nil
    end

    test "a bundled part appears once the extension is on" do
      {:ok, _manifest} = Extensions.enable(@bundled)

      assert {:ok, skill} = Skills.load(@bundled_part)
      assert skill.handler_kind == :reference
      assert skill.enabled
      assert @bundled_part in Enum.map(Skills.list(), & &1.name)
    end

    test "a reference part never enters the runnable catalog" do
      {:ok, _manifest} = Extensions.enable(@bundled)

      # It is read, not run — so it must not become a callable command.
      refute @bundled_part in Enum.map(Skills.catalog_entries(), & &1.name)
    end

    test "turning the extension off removes its parts again" do
      {:ok, _manifest} = Extensions.enable(@bundled)
      assert @bundled_part in Enum.map(Skills.list(), & &1.name)

      :ok = Extensions.disable(@bundled)
      refute @bundled_part in Enum.map(Skills.list(), & &1.name)
    end

    test "a workspace skill of the same name shadows the bundled part", %{root: root} do
      {:ok, _manifest} = Extensions.enable(@bundled)

      dir = Path.join(root, "skills")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, @bundled_part <> ".md"), """
      ---
      name: #{@bundled_part}
      description: Operator override.
      tier: safe
      enabled: true
      handler_kind: reference
      ---

      Mine, not the shipped one.
      """)

      assert {:ok, skill} = Skills.load(@bundled_part)
      assert skill.description == "Operator override."
    end
  end

  describe "add_part/2 — the model attaching a part" do
    setup do
      {:ok, _manifest} = Extensions.enable(@bundled)
      :ok
    end

    test "a written part is always disabled, whatever was asked for" do
      assert {:ok, path} =
               Extensions.add_part(@bundled, %{
                 name: "daily-positions",
                 description: "Summarize one account's positions.",
                 body: "Read the account, then summarize."
               })

      content = File.read!(path)
      assert content =~ "enabled: false"

      # And it is genuinely inert, not merely labelled: an enabled-skill lookup
      # must not resolve it.
      assert Skills.fetch("daily-positions") == :error
      refute "daily-positions" in Enum.map(Skills.list(), & &1.name)
    end

    test "a composition part is disabled too, so a chained sequence cannot self-activate" do
      assert {:ok, path} =
               Extensions.add_part(@bundled, %{
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
      {:ok, path} =
        Extensions.add_part(@bundled, %{name: "stamped", body: "Body.", description: "d"})

      assert File.read!(path) =~ ~s("extension":"#{@bundled}")
    end

    test "a part becomes visible once the operator enables it", %{root: root} do
      {:ok, _path} =
        Extensions.add_part(@bundled, %{name: "later", body: "Body.", description: "d"})

      path = Path.join([root, "extensions", @bundled, "skills", "later.md"])
      File.write!(path, String.replace(File.read!(path), "enabled: false", "enabled: true"))

      assert "later" in Enum.map(Skills.list(), & &1.name)
    end

    test "it refuses to overwrite an existing part" do
      {:ok, _path} = Extensions.add_part(@bundled, %{name: "once", body: "Body."})
      assert {:error, :exists} = Extensions.add_part(@bundled, %{name: "once", body: "Other."})
    end

    test "it refuses a bad name, a bad extension, and an empty body" do
      assert {:error, :invalid_name} =
               Extensions.add_part(@bundled, %{name: "../escape", body: "x"})

      assert {:error, :invalid_name} =
               Extensions.add_part(@bundled, %{name: "Bad Name", body: "x"})

      assert {:error, :not_found} = Extensions.add_part("no-such-ext", %{name: "ok", body: "x"})
      assert {:error, :invalid_id} = Extensions.add_part("../etc", %{name: "ok", body: "x"})
      assert {:error, :empty_body} = Extensions.add_part(@bundled, %{name: "blank", body: "  "})
    end

    test "a composition with no steps is refused" do
      assert {:error, :no_steps} =
               Extensions.add_part(@bundled, %{
                 name: "stepless",
                 body: "Body.",
                 kind: :composition,
                 steps: []
               })
    end

    test "a part cannot escape its extension's directory" do
      {:ok, path} = Extensions.add_part(@bundled, %{name: "contained", body: "Body."})
      assert Path.dirname(path) == Extensions.parts_dir(@bundled)
    end

    test "frontmatter injection through the description is neutralised" do
      {:ok, path} =
        Extensions.add_part(@bundled, %{
          name: "sneaky",
          description: ~s(ok"\nenabled: true\nx: "),
          body: "Body."
        })

      content = File.read!(path)

      # The description must not be able to smuggle in an `enabled: true` line.
      refute content =~ ~r/^enabled: true$/m
      assert content =~ "enabled: false"
      assert {:ok, skill} = Skills.load("sneaky")
      refute skill.enabled
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
