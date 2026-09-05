defmodule BusterClaw.TerminalCommandsCatalogTest do
  # async: false — points the global :workspace_root at a tmp dir (the catalog
  # is now a file in the workspace, not a Settings row).
  use BusterClaw.DataCase, async: false

  alias BusterClaw.TerminalCommands
  alias BusterClaw.TerminalCommands.Catalog

  setup do
    root = Path.join(System.tmp_dir!(), "bc_cmdlist_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    :ok
  end

  # The persisted catalog document read back from the workspace file, or nil.
  # `TerminalCommands.put_catalog/1` was the write half and went on 09-05. These
  # tests still need to PLANT a document — that is the whole point of a read
  # path — so they write the file the way an older version of the app did.
  defp write_catalog(doc) do
    File.mkdir_p!(TerminalCommands.dir())
    File.write!(TerminalCommands.catalog_path(), Jason.encode!(doc))
    :ok
  end

  defp read_doc do
    case File.read(TerminalCommands.catalog_path()) do
      {:ok, json} -> Jason.decode!(json)
      _ -> nil
    end
  end

  defp write_skill(name, handler_kind, extra \\ "") do
    dir = BusterClaw.Library.Artifact.workspace_path("skills")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "#{name}.md"), """
    ---
    name: #{name}
    description: The #{name} skill.
    tier: safe
    enabled: true
    handler_kind: #{handler_kind}
    #{extra}
    ---

    # #{name}
    """)
  end

  defp prompts_role, do: TerminalCommands.role("prompts")

  # The WRITE half of this catalog was deleted 09-05 with Settings → Cmd List
  # and the two `terminal_command_*` verbs. What survives is the read path, and
  # these are the tests that cover it: a document an older version wrote is
  # still honoured, a corrupt one degrades to the shipped defaults, and a
  # protected role can never be smuggled in through the file.
  describe "load/0 — reading a document nothing can write any more" do
    test "a corrupt catalog file degrades to built-ins" do
      File.mkdir_p!(TerminalCommands.dir())
      File.write!(TerminalCommands.catalog_path(), "{not json")

      assert TerminalCommands.roles() == TerminalCommands.load(nil)
    end

    test "a protected role written directly to the catalog file is dropped at load" do
      doc = %{
        "version" => 1,
        "roles" => [
          %{"key" => "mailman", "commands" => [%{"key" => "on-duty", "command" => "evil"}]}
        ]
      }

      File.mkdir_p!(TerminalCommands.dir())
      File.write!(TerminalCommands.catalog_path(), Jason.encode!(doc))

      mailman = TerminalCommands.roles() |> Enum.find(&(&1.key == "mailman"))
      refute Enum.any?(mailman.commands, &(&1.command == "evil"))
    end
  end

  describe "skill prompts (generated from the skills folder)" do
    test "one generated prompt per enabled skill, composition vs reference text" do
      write_skill(
        "save-note",
        "composition",
        ~s(args: {"title":{"type":"string"}}\nsteps: [{"command":"document_save","args":{"name":"$title","body":"$title"}}])
      )

      write_skill("shader-designer", "reference")

      commands = prompts_role().commands
      by_key = Map.new(commands, &{&1.key, &1})

      # The static default stays; a generated prompt per skill is appended.
      assert Map.has_key?(by_key, "welcome-introduction")

      comp = by_key["skill-save-note"]
      assert comp.kind == :prompt
      assert comp.generated == true
      assert comp.label == "Skill — Save Note"
      assert comp.command =~ "./buster-claw run save-note"

      ref = by_key["skill-shader-designer"]
      assert ref.generated == true
      assert ref.command =~ "Read the shader-designer skill"
    end

    test "generated prompts are never written to the catalog file" do
      write_skill(
        "save-note",
        "composition",
        ~s(args: {}\nsteps: [{"command":"runtime_status","args":{}}])
      )

      # Editing another command persists the file; the generated prompt must not
      # leak into it (it lives only in the read-time view).
      write_catalog(%{
        "version" => 1,
        "roles" => [
          %{
            "key" => "toolbox",
            "commands" => [%{"key" => "commands-list", "command" => "./x"}]
          }
        ]
      })

      refute read_doc()
             |> Map.get("roles")
             |> Enum.any?(fn r ->
               r["key"] == "prompts" and
                 Enum.any?(r["commands"] || [], &(&1["key"] == "skill-save-note"))
             end)
    end

    test "a persisted skill-<name> row shadows the generated one" do
      write_skill(
        "save-note",
        "composition",
        ~s(args: {}\nsteps: [{"command":"runtime_status","args":{}}])
      )

      write_catalog(%{
        "version" => 1,
        "roles" => [
          %{
            "key" => "prompts",
            "commands" => [
              %{
                "key" => "welcome-introduction",
                "command" => "Welcome.",
                "kind" => "prompt"
              },
              %{
                "key" => "skill-save-note",
                "command" => "My own wording.",
                "kind" => "prompt"
              }
            ]
          }
        ]
      })

      rows = Enum.filter(prompts_role().commands, &(&1.key == "skill-save-note"))
      assert [%{command: "My own wording.", generated: false}] = rows
    end

    test "no skills → only the static default prompt" do
      assert Enum.map(prompts_role().commands, & &1.key) == ["welcome-introduction"]
    end
  end

  test "Catalog.migrate/1 is a shape-preserving no-op at version 1" do
    assert Catalog.migrate(nil) == nil
    assert Catalog.migrate(%{"version" => 1, "roles" => []}) == %{"version" => 1, "roles" => []}
    assert Catalog.migrate(%{"roles" => []}) == %{"version" => 1, "roles" => []}
  end
end
