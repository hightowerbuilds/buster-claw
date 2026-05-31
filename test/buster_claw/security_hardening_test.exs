defmodule BusterClaw.SecurityHardeningTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.{AgentTools, Commands, Providers, Repo, Vault}
  alias BusterClaw.Commands.Result

  describe "C2: provider secrets encrypted at rest" do
    test "api_key is stored as ciphertext but loads as plaintext" do
      {:ok, provider} =
        Providers.create_provider(%{
          name: "anthropic-test",
          type: "anthropic",
          model: "claude",
          api_key: "sk-ant-super-secret"
        })

      # Raw column value is encrypted, not the plaintext key.
      %{rows: [[stored]]} =
        Repo.query!("SELECT api_key FROM providers WHERE id = ?", [provider.id])

      assert is_binary(stored)
      refute stored == "sk-ant-super-secret"
      assert Vault.encrypted?(stored)

      # Loaded through Ecto, it decrypts transparently.
      assert Providers.get_provider!(provider.id).api_key == "sk-ant-super-secret"
    end
  end

  describe "C1: Result.to_json redacts secrets" do
    test "provider api_key is redacted, not serialized in cleartext" do
      {:ok, provider} =
        Providers.create_provider(%{
          name: "redact-test",
          type: "anthropic",
          model: "claude",
          api_key: "sk-ant-leak-me"
        })

      json = Result.to_json(Providers.get_provider!(provider.id))

      assert json.api_key == "[REDACTED]"
      refute json.api_key == "sk-ant-leak-me"
      # Non-secret fields still pass through.
      assert json.name == "redact-test"
      assert json.type == "anthropic"
    end

    test "an unset secret stays nil so presence is distinguishable" do
      {:ok, ollama} =
        Providers.create_provider(%{name: "ollama-test", type: "ollama", model: "llama3"})

      json = Result.to_json(Providers.get_provider!(ollama.id))
      assert json.api_key == nil
    end
  end

  describe "H1: hook_test is restricted" do
    test "catalog marks hook_test as :restricted" do
      entry = Enum.find(Commands.list_commands(), &(&1.name == "hook_test"))
      assert entry.tier == :restricted
    end

    test "the chat agent cannot see or run hook_test" do
      refute Enum.any?(AgentTools.anthropic_tools(), &(&1.name == "hook_test"))
      assert {:error, message} = AgentTools.execute("hook_test", %{"id" => 1})
      assert message =~ "not available"
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
