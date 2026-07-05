defmodule BusterClaw.TerminalCommandsCatalogTest do
  use BusterClaw.DataCase

  alias BusterClaw.Settings
  alias BusterClaw.TerminalCommands
  alias BusterClaw.TerminalCommands.Catalog

  describe "put_catalog/1 + load/0" do
    test "a persisted catalog round-trips through Settings into the merged view" do
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
      assert Settings.get(TerminalCommands.settings_key()) == nil
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

    test "a corrupt persisted document degrades to built-ins" do
      Settings.put(TerminalCommands.settings_key(), "{not json")

      assert TerminalCommands.roles() == TerminalCommands.load(nil)
    end

    test "a protected role written directly to Settings is dropped at load" do
      doc = %{
        "version" => 1,
        "roles" => [
          %{"key" => "mailman", "commands" => [%{"key" => "on-duty", "command" => "evil"}]}
        ]
      }

      Settings.put(TerminalCommands.settings_key(), Jason.encode!(doc))

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
      assert Settings.get(TerminalCommands.settings_key()) == nil
    end
  end

  describe "save_role_edit/2" do
    test "persists only the diff and mints keys for new rows" do
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

      doc = Settings.get(TerminalCommands.settings_key()) |> Jason.decode!()
      [%{"key" => "toolbox", "commands" => persisted} = entry] = doc["roles"]

      # Diff-only: the unedited built-ins are not persisted.
      assert entry["default_key"] == "runtime-status"
      assert length(persisted) == 2
      assert Enum.any?(persisted, &(&1["key"] == "commands-list"))

      minted = Enum.find(persisted, &(&1["label"] == "Mine"))
      assert minted["key"] =~ ~r/^cmd-[0-9a-f]{8}$/

      toolbox = TerminalCommands.roles() |> Enum.find(&(&1.key == "toolbox"))
      assert Enum.find(toolbox.commands, & &1.default?).key == "runtime-status"
      assert TerminalCommands.startup_command("toolbox") == "./buster-claw run runtime_status"
    end

    test "an edit reverted back to the shipped values removes the role entry" do
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

      doc = Settings.get(TerminalCommands.settings_key()) |> Jason.decode!()
      assert doc["roles"] == []
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
end
