defmodule BusterClaw.CancelAuditEndToEndTest do
  @moduledoc """
  Proof that the cancel audit still fires after the ChatTransport extraction.

  The hook lives on the receive path, which that refactor rewrote. A hook that is
  present but no longer called is the worst outcome available here, because the
  Trading banner and the Explore tutorial both tell the operator that every
  cancellation is recorded on the Security feed. This is the test that makes
  those two sentences true rather than hopeful.
  """
  # async: false — reads the shared Sentinel feed.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Sentinel

  defp start_chat!(opts) do
    conv = "audit-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Chat.start_link(
        [
          conv_id: conv,
          persist: false,
          audit: false,
          spawner: fn _prompt, _opts -> {:ok, :fake_port} end
        ] ++ opts
      )

    {conv, pid}
  end

  defp cancel_event do
    ~s({"type":"assistant","message":{"content":[{"type":"tool_use",) <>
      ~s("name":"mcp__robinhood__cancel_equity_order",) <>
      ~s("input":{"order_id":"abc-123","account_number":"6587"}}]}}) <> "\n"
  end

  defp feed_messages do
    [limit: 50] |> Sentinel.list_events() |> Enum.map(& &1.message)
  end

  test "using the cancel verb lands on the Security feed as it happens" do
    {conv, pid} = start_chat!(audit_tools: ["mcp__robinhood__cancel_equity_order"])
    :ok = Chat.send_message(conv, "cancel my AAPL limit")

    send(pid, {:fake_port, {:data, cancel_event()}})
    # The audit is written from the receive path, so give the cast a moment to
    # be processed before reading the feed.
    _ = :sys.get_state(pid)

    assert Enum.any?(feed_messages(), &(&1 =~ "mcp__robinhood__cancel_equity_order"))

    GenServer.stop(pid)
  end

  test "the recorded line carries the arguments, so the feed says WHICH order" do
    {conv, pid} = start_chat!(audit_tools: ["mcp__robinhood__cancel_equity_order"])
    :ok = Chat.send_message(conv, "cancel it")

    send(pid, {:fake_port, {:data, cancel_event()}})
    _ = :sys.get_state(pid)

    event =
      [limit: 50]
      |> Sentinel.list_events()
      |> Enum.find(&(&1.message =~ "mcp__robinhood__cancel_equity_order"))

    assert event, "the cancellation never reached the feed"
    assert event.metadata["arguments"] =~ "abc-123"
    assert event.metadata["source"] == "agent_chat_tool"

    GenServer.stop(pid)
  end

  # A read is not a write. Auditing every tool call would bury the one that
  # matters in noise.
  test "an ordinary read tool is not audited" do
    {conv, pid} = start_chat!(audit_tools: ["mcp__robinhood__cancel_equity_order"])
    :ok = Chat.send_message(conv, "what do I hold")

    read =
      ~s({"type":"assistant","message":{"content":[{"type":"tool_use",) <>
        ~s("name":"mcp__robinhood__get_equity_positions","input":{}}]}}) <> "\n"

    send(pid, {:fake_port, {:data, read}})
    _ = :sys.get_state(pid)

    refute Enum.any?(feed_messages(), &(&1 =~ "get_equity_positions"))

    GenServer.stop(pid)
  end

  # A conversation that was never given the list must not start auditing.
  test "a chat with no audit_tools records nothing" do
    {conv, pid} = start_chat!([])
    :ok = Chat.send_message(conv, "cancel it")

    send(pid, {:fake_port, {:data, cancel_event()}})
    _ = :sys.get_state(pid)

    refute Enum.any?(feed_messages(), &(&1 =~ "mcp__robinhood__cancel_equity_order"))

    GenServer.stop(pid)
  end
end
