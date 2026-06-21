defmodule BusterClaw.TerminalCommandsTest do
  use ExUnit.Case, async: true

  alias BusterClaw.TerminalCommands

  test "lists the Mailman role and approved commands" do
    assert %{key: "mailman", label: "Mailman", commands: commands} =
             TerminalCommands.role("mailman")

    assert Enum.any?(commands, &(&1.command == "./buster-claw mailman poll"))
    assert Enum.any?(commands, &(&1.command == "./buster-claw mailman poll --once"))

    assert Enum.any?(
             commands,
             &(&1.command ==
                 "./buster-claw mailman poll 2>&1 | tee -a shift/2026-06-08/mailman-native-poll.log")
           )
  end

  test "consolidates Autopilot commands into the Shift role" do
    assert %{key: "shift", commands: commands} = TerminalCommands.role("shift")

    # Autopilot aliases now resolve to the consolidated Shift role.
    assert %{key: "shift"} = TerminalCommands.role("autopilot")
    assert %{key: "shift"} = TerminalCommands.role("auto")
    assert %{key: "shift"} = TerminalCommands.role("hands-off")

    # Both the shift controls and the autopilot commands live in the one group.
    assert Enum.any?(commands, &(&1.command =~ "shift start --json"))
    assert Enum.any?(commands, &(&1.command == "./buster-claw autopilot"))
    assert Enum.any?(commands, &(&1.command =~ "while true; do ./buster-claw autopilot"))

    # Opening a shift terminal reports status, not autopilot — there is no longer a
    # standalone "autopilot" startup profile.
    assert TerminalCommands.startup_command("shift") == "./buster-claw shift status"
    refute TerminalCommands.startup_command("autopilot")
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

    assert TerminalCommands.startup_command("mailman") == "./buster-claw mailman poll"

    refute TerminalCommands.startup_profile_for_role("unknown-role")
    refute TerminalCommands.startup_command("unknown-profile")
  end
end
