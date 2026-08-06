defmodule BusterClaw.OrderCancelTest do
  @moduledoc """
  The chat holds one write verb.

  Operator decision 08-04, against the recommendation on record: cancellation
  happens on the model's say-so rather than through a confirmation card. That
  trades STRUCTURAL safety (the model held no verb) for BEHAVIOURAL safety (it
  holds one and is told how to use it). These tests pin what did NOT get traded
  away with it.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Agent.Chat
  alias BusterClaw.{ModelPolicy, Sentinel, Trading}

  describe "the toolset" do
    test "the chat can cancel, and still cannot place or amend" do
      tools = Trading.chat_tools()

      assert "mcp__robinhood__cancel_equity_order" in tools
      refute "mcp__robinhood__place_equity_order" in tools
      refute "mcp__robinhood__place_option_order" in tools
    end

    test "the cancel verb reaches the CLI allowlist, not just the list" do
      args = Trading.read_only_cli_args()
      allowed = args |> Enum.drop_while(&(&1 != "--allowedTools")) |> Enum.at(1)

      assert allowed =~ "mcp__robinhood__cancel_equity_order"
    end

    # `@read_tools` keeps meaning what its name says; the exception is separate
    # so it stays visible rather than hiding in an alphabetical list of get_*.
    test "the write verb is not smuggled into the read list" do
      reads = Trading.chat_tools() -- ["mcp__robinhood__cancel_equity_order"]
      assert Enum.all?(reads, &String.starts_with?(&1, "mcp__robinhood__get_"))
    end
  end

  describe "the model that holds it" do
    # The operator chose to SHARE :order_submit rather than add a surface, so a
    # cheaper model can never reach cancelling without also reaching placing.
    test "the trading chat runs on the money surface's model, not the chat's" do
      {:ok, _} = ModelPolicy.put_model(:claude, :chat, "claude-haiku-4-5")
      {:ok, _} = ModelPolicy.put_model(:claude, :order_submit, "claude-opus-5")

      assert Keyword.fetch!(Trading.chat_opts(), :model) == "claude-opus-5"
    end

    test "and therefore inherits the money floor" do
      {:ok, _} = ModelPolicy.put_model(:claude, :default, "claude-haiku-4-5")

      # The floor lifts it, exactly as it does for placement.
      assert Keyword.fetch!(Trading.chat_opts(), :model) == "claude-sonnet-5"
    end
  end

  describe "the record that replaces the click" do
    test "the cancel verb is registered for auditing" do
      assert "mcp__robinhood__cancel_equity_order" in Keyword.fetch!(
               Trading.chat_opts(),
               :audit_tools
             )
    end

    # The whole point, end to end: the registration above has to actually reach
    # the feed. A list nobody reads would leave the banner's promise — "every
    # cancellation is recorded on the Security feed" — false.
    test "a cancel call lands on the Security feed as it happens" do
      conv = run_tools([{"mcp__robinhood__cancel_equity_order", %{"order_id" => "abc-123"}}])

      assert %{category: "outbound_send", severity: "warning"} =
               event = audit_line(conv)

      assert event.message =~ "mcp__robinhood__cancel_equity_order"
      # The arguments matter: which order was cancelled is the fact the operator
      # lost when they gave up the card.
      assert event.metadata["arguments"] =~ "abc-123"
      assert event.metadata["tool"] == "mcp__robinhood__cancel_equity_order"
    end

    # If reads were audited too, the one line that matters would be buried in
    # eleven that don't.
    test "reading the order list does not" do
      conv =
        run_tools([
          {"mcp__robinhood__get_equity_orders", %{}},
          {"mcp__robinhood__get_accounts", %{}}
        ])

      refute audit_line(conv)
    end
  end

  # Drive a real `Agent.Chat` with a scripted stream, carrying the audit
  # registration the Trading profile actually ships.
  defp run_tools(calls) do
    conv = "cancel-audit-#{System.unique_integer([:positive])}"
    Chat.subscribe(conv)

    {:ok, _pid} =
      Chat.start_link(
        conv_id: conv,
        audit_tools: Keyword.fetch!(Trading.chat_opts(), :audit_tools),
        spawner: scripting_spawner(calls)
      )

    :ok = Chat.send_message(conv, "cancel that order")
    assert_receive {:agent_chat, ^conv, {:status, :idle}}, 2_000

    conv
  end

  defp scripting_spawner(calls) do
    fn _prompt, _opts ->
      chat = self()
      port = make_ref()

      lines =
        Enum.map(calls, fn {tool, input} ->
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [%{"type" => "tool_use", "name" => tool, "input" => input}]
            }
          }
        end) ++ [%{"type" => "result", "result" => "done"}]

      spawn(fn ->
        Enum.each(lines, &send(chat, {port, {:data, Jason.encode!(&1) <> "\n"}}))
        send(chat, {port, {:exit_status, 0}})
      end)

      {:ok, port}
    end
  end

  defp audit_line(conv) do
    Enum.find(Sentinel.list_events(), &(&1.metadata["conv_id"] == conv))
  end

  describe "the prompt, which is now the safety" do
    test "grants the verb plainly rather than implying it" do
      prompt = Keyword.fetch!(Trading.chat_opts(), :append_system_prompt)

      assert prompt =~ "You may CANCEL a resting order"
      assert prompt =~ "no confirmation card in front of it"
    end

    # The old text promised the model would never hold a cancel verb. Leaving
    # that in while shipping the verb would be the worst of both.
    test "no longer claims it cannot cancel" do
      prompt = Keyword.fetch!(Trading.chat_opts(), :append_system_prompt)

      refute prompt =~ "You have NO order tool and you never will"
      refute prompt =~ "You cannot\n    place, amend, or cancel anything"
    end

    test "still refuses placing without a card" do
      prompt = Keyword.fetch!(Trading.chat_opts(), :append_system_prompt)

      assert prompt =~ "You may NOT place or amend"
      assert prompt =~ "their click, not your"
      assert prompt =~ "is what places it"
    end

    # Each of these is a failure mode with a name: stale ids, ambiguous targets,
    # wrong account, and a cancel that lands after a fill.
    test "carries the four rules that are now the only guard rails" do
      prompt = Keyword.fetch!(Trading.chat_opts(), :append_system_prompt)

      assert prompt =~ "get_equity_orders FIRST"
      assert prompt =~ "STOP and ask which"
      assert prompt =~ ~s("agentic": true)
      assert prompt =~ "UNKNOWN"
    end
  end
end
