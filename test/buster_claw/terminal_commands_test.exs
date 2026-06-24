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
