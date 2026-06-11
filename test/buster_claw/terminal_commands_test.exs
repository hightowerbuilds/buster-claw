defmodule BusterClaw.TerminalCommandsTest do
  use ExUnit.Case, async: true

  alias BusterClaw.TerminalCommands

  test "lists the Mailman role and approved commands" do
    assert [%{key: "mailman", label: "Mailman", commands: commands}] = TerminalCommands.roles()

    assert Enum.any?(commands, &(&1.command == "./buster-claw mailman poll"))
    assert Enum.any?(commands, &(&1.command == "./buster-claw mailman poll --once"))

    assert Enum.any?(
             commands,
             &(&1.command ==
                 "./buster-claw mailman poll 2>&1 | tee -a shift/2026-06-08/mailman-native-poll.log")
           )
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
