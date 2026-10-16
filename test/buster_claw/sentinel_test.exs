defmodule BusterClaw.SentinelTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Sentinel

  describe "observe/4" do
    test "persists, classifies, redacts secrets, and broadcasts" do
      Phoenix.PubSub.subscribe(BusterClaw.PubSub, Sentinel.topic())

      assert {:ok, event} =
               Sentinel.observe(
                 :security_block,
                 "blocked gmail_send",
                 %{command: "gmail_send", refresh_token: "super-secret", caller: :mcp}
               )

      assert event.category == "security_block"
      assert event.severity == "critical"
      assert event.caller == "mcp"
      assert event.metadata["command"] == "gmail_send"
      assert event.metadata["refresh_token"] == "[redacted]"

      assert_receive {:security_event, %{id: id}}
      assert id == event.id
    end

    test "classifies command_invoke by tier" do
      assert {:ok, %{severity: "warning"}} =
               Sentinel.observe(:command_invoke, "x", %{tier: :restricted})

      assert {:ok, %{severity: "notice"}} =
               Sentinel.observe(:command_invoke, "y", %{tier: :safe})
    end

    test "an explicit :severity override wins over the rubric" do
      assert {:ok, %{severity: "info"}} =
               Sentinel.observe(:command_invoke, "z", %{tier: :restricted}, severity: :info)
    end

    test "non-map metadata never raises" do
      assert {:ok, event} = Sentinel.observe(:command_invoke, "weird", {:a, :tuple})
      assert is_map(event.metadata)
    end

    test "redacts secret-shaped values carried under non-sensitive keys" do
      assert {:ok, event} =
               Sentinel.observe(:command_invoke, "leaky", %{
                 code: "ghp_0123456789abcdefghijABCDEFGHIJ0123",
                 url: "https://api.example.com/cb?auth=Bearer sk-abcdefghijklmnop1234567890",
                 card: "4242 4242 4242 4242",
                 note: "just a normal sentence with no secrets in it"
               })

      assert event.metadata["code"] == "[redacted]"
      refute event.metadata["url"] =~ "sk-"
      refute event.metadata["url"] =~ "Bearer"
      refute event.metadata["card"] =~ "4242"
      # Conservative: ordinary prose is left untouched.
      assert event.metadata["note"] == "just a normal sentence with no secrets in it"
    end
  end

  describe "list / count / acknowledge" do
    test "lists newest-first and acknowledges" do
      {:ok, _e1} = Sentinel.observe(:command_invoke, "first", %{tier: :restricted})
      {:ok, e2} = Sentinel.observe(:security_block, "second", %{})

      assert [newest | _] = Sentinel.list_events(limit: 10)
      assert newest.id == e2.id

      assert Sentinel.count_unacknowledged() == 2
      assert {:ok, _} = Sentinel.acknowledge(e2.id)
      assert Sentinel.count_unacknowledged() == 1
      assert {:ok, 1} = Sentinel.acknowledge_all()
      assert Sentinel.count_unacknowledged() == 0
    end

    test "acknowledge/1 reports missing ids" do
      assert {:error, :not_found} = Sentinel.acknowledge(999_999)
    end
  end
end
