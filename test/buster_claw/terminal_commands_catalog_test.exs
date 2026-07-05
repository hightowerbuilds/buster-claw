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
  defp read_doc do
    case File.read(TerminalCommands.catalog_path()) do
      {:ok, json} -> Jason.decode!(json)
      _ -> nil
    end
  end

  describe "put_catalog/1 + load/0" do
    test "a persisted catalog round-trips through the workspace file into the merged view" do
      doc = %{
        "version" => 1,
        "roles" => [
          %{
            "key" => "toolbox",
            "commands" => [
              %{"key" => "commands-list", "command" => "./buster-claw commands --json"}
            ]
          }
        ]
      }

      assert :ok = TerminalCommands.put_catalog(doc)

      toolbox = TerminalCommands.roles() |> Enum.find(&(&1.key == "toolbox"))

      assert Enum.find(toolbox.commands, &(&1.key == "commands-list")).command ==
               "./buster-claw commands --json"

      # The merged view drives startup-profile resolution too.
      assert TerminalCommands.startup_command("mailman") == "./buster-claw on-duty"
    end

    test "refuses a document that touches a protected role" do
      doc = %{
        "version" => 1,
        "roles" => [
          %{"key" => "mailman", "commands" => [%{"key" => "on-duty", "command" => "evil"}]}
        ]
      }

      assert {:error, %Ecto.Changeset{}} = TerminalCommands.put_catalog(doc)
      refute File.exists?(TerminalCommands.catalog_path())
    end

    test "refuses multiline shell commands, including via a forged prompt kind" do
      forged = %{
        "version" => 1,
        "roles" => [
          %{
            "key" => "toolbox",
            "commands" => [
              %{
                "key" => "commands-list",
                "command" => "./buster-claw commands\nrm -rf /",
                "kind" => "prompt"
              }
            ]
          }
        ]
      }

      assert {:error, changeset} = TerminalCommands.put_catalog(forged)
      refute changeset.valid?
    end

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

    test "broadcasts the merged catalog on save and reset" do
      TerminalCommands.subscribe()

      doc = %{
        "version" => 1,
        "roles" => [
          %{"key" => "toolbox", "commands" => [%{"key" => "mine", "command" => "echo hi"}]}
        ]
      }

      assert :ok = TerminalCommands.put_catalog(doc)
      assert_receive {:terminal_commands_updated, roles} when is_list(roles)

      assert :ok = TerminalCommands.reset_catalog()
      assert_receive {:terminal_commands_updated, _roles}
      # Reset restores the file to the full shipped defaults (non-protected).
      assert read_doc()["roles"] |> Enum.map(& &1["key"]) == ["queue", "toolbox", "prompts"]
    end
  end

  describe "save_role_edit/2" do
    test "persists the full role and mints keys for new rows" do
      base = TerminalCommands.role_edit("toolbox")

      params = %{
        "default_key" => "runtime-status",
        "commands" =>
          base.commands
          |> Enum.with_index()
          |> Map.new(fn {c, i} ->
            {to_string(i),
             %{
               "id" => c.id,
               "key" => c.key,
               "label" => c.label || "",
               "description" => c.description || "",
               "command" =>
                 if(c.key == "commands-list", do: "./buster-claw commands --json", else: c.command),
               "kind" => c.kind
             }}
          end)
          |> Map.put("3", %{"key" => "", "label" => "Mine", "command" => "echo mine", "kind" => "shell"})
      }

      assert {:ok, %{commands_changed: true}} = TerminalCommands.save_role_edit(base, params)

      [%{"key" => "toolbox", "commands" => persisted} = entry] = read_doc()["roles"]

      # Full role: every command is written (the workspace file shows the whole
      # list), not a sparse diff — 3 built-ins + the new one.
      assert entry["default_key"] == "runtime-status"
      assert length(persisted) == 4
      assert Enum.any?(persisted, &(&1["key"] == "commands-list"))
      assert Enum.any?(persisted, &(&1["key"] == "runtime-status"))
      assert Enum.any?(persisted, &(&1["key"] == "memory-search"))

      minted = Enum.find(persisted, &(&1["label"] == "Mine"))
      assert minted["key"] =~ ~r/^cmd-[0-9a-f]{8}$/

      toolbox = TerminalCommands.roles() |> Enum.find(&(&1.key == "toolbox"))
      assert Enum.find(toolbox.commands, & &1.default?).key == "runtime-status"
      assert TerminalCommands.startup_command("toolbox") == "./buster-claw run runtime_status"
    end

    test "an unedited save persists the full role, reporting no execution change" do
      base = TerminalCommands.role_edit("queue")

      params = %{
        "commands" =>
          base.commands
          |> Enum.with_index()
          |> Map.new(fn {c, i} ->
            {to_string(i),
             %{
               "id" => c.id,
               "key" => c.key,
               "label" => c.label || "",
               "description" => c.description || "",
               "command" => c.command,
               "kind" => c.kind
             }}
          end)
      }

      assert {:ok, %{commands_changed: false}} = TerminalCommands.save_role_edit(base, params)

      [%{"key" => "queue", "commands" => persisted}] = read_doc()["roles"]
      assert length(persisted) == length(base.commands)
    end

    test "refuses to drop a built-in command" do
      base = TerminalCommands.role_edit("toolbox")
      [first | _rest] = base.commands

      params = %{
        "commands" => %{
          "0" => %{
            "id" => first.id,
            "key" => first.key,
            "command" => first.command,
            "kind" => first.kind
          }
        }
      }

      assert {:error, changeset} = TerminalCommands.save_role_edit(base, params)
      assert {message, _meta} = changeset.errors[:commands]
      assert message =~ "built-in commands cannot be deleted"
    end

    test "protected roles have no editor surface" do
      assert TerminalCommands.role_edit("mailman") == nil
      assert TerminalCommands.role_edit("agent-setup") == nil
    end
  end

  describe "reset_role/1" do
    test "restores the shipped commands for one role" do
      doc = %{
        "version" => 1,
        "roles" => [
          %{
            "key" => "toolbox",
            "commands" => [%{"key" => "commands-list", "command" => "./custom"}]
          }
        ]
      }

      assert :ok = TerminalCommands.put_catalog(doc)
      assert :ok = TerminalCommands.reset_role("toolbox")

      toolbox = TerminalCommands.roles() |> Enum.find(&(&1.key == "toolbox"))

      assert Enum.find(toolbox.commands, &(&1.key == "commands-list")).command ==
               "./buster-claw commands"
    end

    test "refuses protected roles" do
      assert {:error, :protected} = TerminalCommands.reset_role("mailman")
    end
  end

  test "Catalog.migrate/1 is a shape-preserving no-op at version 1" do
    assert Catalog.migrate(nil) == nil
    assert Catalog.migrate(%{"version" => 1, "roles" => []}) == %{"version" => 1, "roles" => []}
    assert Catalog.migrate(%{"roles" => []}) == %{"version" => 1, "roles" => []}
  end

  describe "set_command/1 (agent-facing single-command upsert)" do
    test "edits an existing command's text and refreshes the merged view" do
      assert {:ok, %{commands_changed: true}} =
               TerminalCommands.set_command(%{
                 "role_key" => "toolbox",
                 "command_key" => "commands-list",
                 "command" => "./buster-claw commands --json"
               })

      edited =
        TerminalCommands.role("toolbox").commands
        |> Enum.find(&(&1.key == "commands-list"))

      assert edited.command == "./buster-claw commands --json"
    end

    test "a label-only edit reports commands_changed: false" do
      assert {:ok, %{commands_changed: false}} =
               TerminalCommands.set_command(%{
                 "role_key" => "toolbox",
                 "command_key" => "commands-list",
                 "label" => "Renamed"
               })

      assert TerminalCommands.role("toolbox").commands
             |> Enum.find(&(&1.key == "commands-list"))
             |> Map.get(:label) == "Renamed"
    end

    test "adds a new user command when the key is unknown" do
      assert {:ok, %{commands_changed: true}} =
               TerminalCommands.set_command(%{
                 "role_key" => "toolbox",
                 "command_key" => "my-cmd",
                 "command" => "./buster-claw run runtime_status",
                 "label" => "Mine"
               })

      added = TerminalCommands.role("toolbox").commands |> Enum.find(&(&1.key == "my-cmd"))
      assert added.command == "./buster-claw run runtime_status"
      assert added.builtin == false
    end

    test "infers the prompt kind for a multiline prompts-role addition" do
      assert {:ok, _result} =
               TerminalCommands.set_command(%{
                 "role_key" => "prompts",
                 "command_key" => "my-prompt",
                 "command" => "Do the thing.\nThen the other thing."
               })

      added = TerminalCommands.role("prompts").commands |> Enum.find(&(&1.key == "my-prompt"))
      assert added.kind == :prompt
    end

    test "refuses a protected role and persists nothing" do
      assert {:error, :protected} =
               TerminalCommands.set_command(%{
                 "role_key" => "mailman",
                 "command_key" => "on-duty",
                 "command" => "./buster-claw off-duty"
               })

      refute File.exists?(TerminalCommands.catalog_path())
    end

    test "an unknown command key with no command text is missing_command" do
      assert {:error, :missing_command} =
               TerminalCommands.set_command(%{
                 "role_key" => "toolbox",
                 "command_key" => "ghost",
                 "label" => "no text"
               })
    end

    test "rejects a multiline shell command with a changeset error" do
      assert {:error, %Ecto.Changeset{}} =
               TerminalCommands.set_command(%{
                 "role_key" => "toolbox",
                 "command_key" => "commands-list",
                 "command" => "line one\nline two"
               })
    end

    test "an unknown role is not found" do
      assert {:error, :not_found} =
               TerminalCommands.set_command(%{
                 "role_key" => "nope",
                 "command_key" => "x",
                 "command" => "echo hi"
               })
    end
  end

  describe "terminal_command_set / terminal_command_list commands" do
    alias BusterClaw.Commands

    test "list omits protected roles; set edits via dispatch and refreshes live" do
      {:ok, %{roles: roles}} =
        Commands.call("terminal_command_list", %{}, caller: :trusted)

      keys = Enum.map(roles, & &1.role_key)
      assert "toolbox" in keys
      refute "mailman" in keys

      assert {:ok, %{commands_changed: true, role_key: "toolbox"}} =
               Commands.call(
                 "terminal_command_set",
                 %{
                   "role_key" => "toolbox",
                   "command_key" => "commands-list",
                   "command" => "./buster-claw commands --json"
                 },
                 caller: :trusted
               )

      assert TerminalCommands.role("toolbox").commands
             |> Enum.find(&(&1.key == "commands-list"))
             |> Map.get(:command) == "./buster-claw commands --json"
    end

    test "a protected-role edit surfaces as an error through dispatch" do
      assert {:error, :protected_role} =
               Commands.call(
                 "terminal_command_set",
                 %{"role_key" => "mailman", "command_key" => "on-duty", "command" => "x"},
                 caller: :trusted
               )
    end

    test "a validation failure returns flattened changeset errors" do
      assert {:error, {:invalid, errors}} =
               Commands.call(
                 "terminal_command_set",
                 %{
                   "role_key" => "toolbox",
                   "command_key" => "commands-list",
                   "command" => "line one\nline two"
                 },
                 caller: :trusted
               )

      assert is_map(errors)
    end
  end
end
