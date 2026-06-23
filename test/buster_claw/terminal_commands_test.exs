defmodule BusterClaw.TerminalCommandsTest do
  use ExUnit.Case, async: true

  alias BusterClaw.TerminalCommands

  test "lists the On Duty role pointing at the consolidated on-duty verb" do
    assert %{key: "mailman", label: "On Duty", commands: commands} =
             TerminalCommands.role("mailman")

    # Consolidated to a single front-door verb (the old mailman-poll commands are gone).
    assert Enum.any?(commands, &(&1.command == "./buster-claw on-duty"))
    assert Enum.any?(commands, &(&1.command == "./buster-claw on-duty --interval 60"))
    assert Enum.any?(commands, &(&1.command == "./buster-claw off-duty"))
    refute Enum.any?(commands, &(&1.command =~ "mailman poll"))
  end

  test "shift role exposes status + the consolidated on-duty / off-duty verbs" do
    assert %{key: "shift", commands: commands} = TerminalCommands.role("shift")

    assert Enum.any?(commands, &(&1.command == "./buster-claw on-duty"))
    assert Enum.any?(commands, &(&1.command == "./buster-claw off-duty"))
    assert Enum.any?(commands, &(&1.command == "./buster-claw shift status"))

    # Autopilot has been removed: no commands and no aliases resolve to it.
    refute Enum.any?(commands, &(&1.command =~ "autopilot"))
    refute TerminalCommands.role("autopilot")
    refute TerminalCommands.role("hands-off")

    # Opening a shift terminal reports status.
    assert TerminalCommands.startup_command("shift") == "./buster-claw shift status"
  end

  test "lists the Claude Code install role for onboarding" do
    assert %{key: "agent-setup", startup_profile: "agent-setup"} =
             TerminalCommands.role("agent-setup")

    assert TerminalCommands.startup_command("agent-setup") ==
             "brew install --cask claude-code"
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
end
