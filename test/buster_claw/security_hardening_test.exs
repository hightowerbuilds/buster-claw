defmodule BusterClaw.SecurityHardeningTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Commands

  describe "H1: hook_test is restricted" do
    test "catalog marks hook_test as :restricted" do
      entry = Enum.find(Commands.list_commands(), &(&1.name == "hook_test"))
      assert entry.tier == :restricted
    end
  end

  describe "H2: MCP/agent callers cannot reach restricted commands via Commands.call/3" do
    alias BusterClaw.Sentinel.Pending

    test "a refused restricted command is recorded as pending with secrets redacted" do
      Phoenix.PubSub.subscribe(BusterClaw.PubSub, Pending.topic())

      assert {:error, :requires_confirmation} =
               Commands.call(
                 "gmail_send",
                 %{"to" => "x@example.com", "refresh_token" => "super-secret-value"},
                 caller: :mcp
               )

      # Match the specific broadcast for THIS call (carries refresh_token), so a
      # concurrent gmail_send refusal from another test can't satisfy it.
      assert_receive {:pending_action,
                      %{command: "gmail_send", caller: :mcp, args: %{"refresh_token" => redacted}} =
                        entry}

      # Secret-looking args never land in the visible pending record.
      assert redacted == "[redacted]"
      assert entry.args["to"] == "x@example.com"
    end

    test "a safe command for an untrusted caller executes normally" do
      assert {:ok, _snapshot} = Commands.call("runtime_status", %{}, caller: :mcp)
    end
  end
end
