defmodule BusterClaw.TerminalCommandsTest do
  use ExUnit.Case, async: true

  alias BusterClaw.TerminalCommands

  test "On Duty is the single role for the duty verbs + shift status" do
    assert %{key: "mailman", label: "On Duty", commands: commands} =
             TerminalCommands.role("mailman")

    # Consolidated to a single front-door verb (the old mailman-poll commands are gone).
    assert Enum.any?(commands, &(&1.command == "./buster-claw on-duty"))
    assert Enum.any?(commands, &(&1.command == "./buster-claw on-duty --interval 60"))
    assert Enum.any?(commands, &(&1.command == "./buster-claw shift status"))
    refute Enum.any?(commands, &(&1.command =~ "mailman poll"))

    # Exactly one Go On Duty and one Off Duty — no duplicate from a separate Shift role.
    assert Enum.count(commands, &(&1.command == "./buster-claw on-duty")) == 1
    assert Enum.count(commands, &(&1.command == "./buster-claw off-duty")) == 1

    # Autopilot is gone; nothing resolves to it.
    refute Enum.any?(commands, &(&1.command =~ "autopilot"))
    refute TerminalCommands.role("autopilot")
  end

  test "the old Shift role folded into On Duty (aliases still resolve)" do
    # No standalone Shift role; shift/on-shift/duty now resolve to On Duty.
    assert %{key: "mailman"} = TerminalCommands.role("shift")
    assert %{key: "mailman"} = TerminalCommands.role("on-shift")
    assert %{key: "mailman"} = TerminalCommands.role("duty")

    # There is no longer a standalone "shift" startup profile.
    refute TerminalCommands.startup_command("shift")
  end

  test "the Claude Code install role stays resolvable but is hidden from the menu" do
    # Still resolvable — the Setup wizard's install button + startup-profile
    # validation depend on it.
    assert %{key: "agent-setup", startup_profile: "agent-setup"} =
             TerminalCommands.role("agent-setup")

    assert TerminalCommands.startup_command("agent-setup") ==
             "brew install --cask claude-code"

    # ...but not surfaced in the terminal command menu.
    assert Enum.any?(TerminalCommands.roles(), &(&1.key == "agent-setup"))
    refute Enum.any?(TerminalCommands.menu_roles(), &(&1.key == "agent-setup"))
  end

  test "does not surface the dev server (dev-only, not a runtime menu command)" do
    refute TerminalCommands.role("server")
    refute TerminalCommands.role("phx")
    refute TerminalCommands.startup_command("server")
  end

  test "resolves Mailman aliases" do
    assert %{key: "mailman"} = TerminalCommands.role("mailman")
    assert %{key: "mailman"} = TerminalCommands.role("mail-triage")
    assert %{key: "mailman"} = TerminalCommands.role("gmail-poller")
  end

  test "resolves startup profile and command from the catalog" do
    assert TerminalCommands.startup_profile_for_role("mail-triage") == "mailman"

    assert TerminalCommands.startup_command("mailman") == "./buster-claw on-duty"

    refute TerminalCommands.startup_profile_for_role("unknown-role")
    refute TerminalCommands.startup_command("unknown-profile")
  end

  describe "load/1 merge semantics" do
    test "an empty or missing user catalog is a no-op" do
      builtin = TerminalCommands.load(nil)

      assert TerminalCommands.load(%{"version" => 1, "roles" => []}) == builtin
      assert TerminalCommands.load(%{"version" => 1}) == builtin
      # Unrecognizable documents degrade to built-ins, never crash.
      assert TerminalCommands.load(%{"roles" => "garbage"}) == builtin

      assert Enum.map(builtin, & &1.key) ==
               Enum.map(TerminalCommands.builtin_roles(), & &1.key)
    end

    test "protected roles are injected from the built-ins even if the doc names them" do
      doc = %{
        "version" => 1,
        "roles" => [
          %{
            "key" => "mailman",
            "commands" => [
              %{"key" => "on-duty", "command" => "rm -rf /", "label" => "Hijacked"}
            ]
          }
        ]
      }

      merged = TerminalCommands.load(doc)
      mailman = Enum.find(merged, &(&1.key == "mailman"))

      assert mailman.protected
      assert Enum.any?(mailman.commands, &(&1.command == "./buster-claw on-duty"))
      refute Enum.any?(mailman.commands, &(&1.command =~ "rm -rf"))
    end

    test "user overrides win on label/description/command for non-protected roles" do
      doc = %{
        "version" => 1,
        "roles" => [
          %{
            "key" => "toolbox",
            "commands" => [
              %{
                "key" => "commands-list",
                "label" => "My Commands",
                "command" => "./buster-claw commands --json"
              }
            ]
          }
        ]
      }

      toolbox = TerminalCommands.load(doc) |> Enum.find(&(&1.key == "toolbox"))
      overridden = Enum.find(toolbox.commands, &(&1.key == "commands-list"))

      assert overridden.label == "My Commands"
      assert overridden.command == "./buster-claw commands --json"
      assert overridden.builtin
    end

    test "forward-compat: built-in commands absent from the user doc still appear" do
      # The doc only knows one toolbox command; the other shipped commands
      # (as if added by a newer app version) must still show up.
      doc = %{
        "version" => 1,
        "roles" => [
          %{
            "key" => "toolbox",
            "commands" => [%{"key" => "commands-list", "command" => "./buster-claw commands"}]
          }
        ]
      }

      toolbox = TerminalCommands.load(doc) |> Enum.find(&(&1.key == "toolbox"))

      assert Enum.any?(toolbox.commands, &(&1.key == "runtime-status"))
      assert Enum.any?(toolbox.commands, &(&1.key == "memory-search"))
    end

    test "user-added commands and user-only roles append at the end" do
      doc = %{
        "version" => 1,
        "roles" => [
          %{
            "key" => "toolbox",
            "commands" => [
              %{"key" => "my-status", "command" => "./buster-claw run runtime_status"}
            ]
          },
          %{
            "key" => "my-flows",
            "commands" => [%{"key" => "hello", "command" => "echo hello"}]
          }
        ]
      }

      merged = TerminalCommands.load(doc)

      toolbox = Enum.find(merged, &(&1.key == "toolbox"))
      assert List.last(toolbox.commands).key == "my-status"
      refute List.last(toolbox.commands).builtin

      assert List.last(merged).key == "my-flows"
      assert List.last(merged).label == "My Flows"
      refute List.last(merged).protected
    end

    test "a user default_key moves the role default" do
      doc = %{
        "version" => 1,
        "roles" => [%{"key" => "queue", "default_key" => "dispatch-claim", "commands" => []}]
      }

      queue = TerminalCommands.load(doc) |> Enum.find(&(&1.key == "queue"))

      assert Enum.find(queue.commands, & &1.default?).key == "dispatch-claim"
    end

    test "multiline shell commands never survive the merge (defense in depth)" do
      doc = %{
        "version" => 1,
        "roles" => [
          %{
            "key" => "toolbox",
            "commands" => [
              %{"key" => "commands-list", "command" => "./buster-claw commands\nrm -rf /"},
              %{"key" => "sneaky", "command" => "echo hi\nrm -rf /"}
            ]
          }
        ]
      }

      toolbox = TerminalCommands.load(doc) |> Enum.find(&(&1.key == "toolbox"))

      # The override reverts to the shipped command; the added row is dropped.
      assert Enum.find(toolbox.commands, &(&1.key == "commands-list")).command ==
               "./buster-claw commands"

      refute Enum.any?(toolbox.commands, &(&1.key == "sneaky"))
    end

    test "prompts keep their multiline-capable prompt kind" do
      prompts = TerminalCommands.load(nil) |> Enum.find(&(&1.key == "prompts"))

      assert Enum.all?(prompts.commands, &(&1.kind == :prompt))
    end
  end
end
