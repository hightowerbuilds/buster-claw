defmodule BusterClaw.Agent.ChatSurfaceSafetyTest do
  @moduledoc """
  Phase 6's surface-specific rules — the three places where steering could
  quietly weaken a control that exists for a reason.

  Each is a case where a steered message is NOT an ordinary turn, and treating
  it like one has a consequence beyond the transcript.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.FakeChatTransport

  defp start_chat(opts \\ []) do
    conv_id = "safety-#{System.unique_integer([:positive])}"
    Chat.subscribe(conv_id)

    {:ok, pid} =
      Chat.start_link(
        [
          conv_id: conv_id,
          spawner: fn _p, _o -> {:ok, make_ref()} end,
          transport_mod: FakeChatTransport,
          persist: false,
          audit: false
        ] ++ opts
      )

    %{conv: conv_id, pid: pid}
  end

  describe "sound: steering does not ring" do
    test "accepting a steer is silent — the agent has not gone quiet" do
      ctx = start_chat()
      {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)

      # The ring means "the agent went quiet, come look". A steer is the
      # opposite: the operator is right there, and the turn is still going.
      # `Chat` rings only from `dispatch_next([])`, which a steer never reaches.
      assert {:ok, :steered} = Chat.submit(ctx.conv, "redirect", delivery: :steer)
      assert Chat.running?(ctx.conv)
      assert Chat.queue(ctx.conv) == []
    end

    test "queueing does not ring either — there is still work outstanding" do
      ctx = start_chat()
      {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)

      assert {:ok, :queued} = Chat.submit(ctx.conv, "next", delivery: :next)
      assert Chat.running?(ctx.conv)
    end
  end

  describe "the turn counter" do
    test "a steered message does not start a turn" do
      ctx = start_chat()
      {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)

      turn_before = :sys.get_state(ctx.pid).turn_ref
      {:ok, :steered} = Chat.submit(ctx.conv, "redirect", delivery: :steer)

      # Same turn. A steer belongs to the work already running — if it started
      # a new one, everything scoped per-turn (budgets, brakes, counters) would
      # silently reset mid-flight.
      assert :sys.get_state(ctx.pid).turn_ref == turn_before
    end

    test "a steered message IS still recorded as operator input" do
      ctx = start_chat()
      {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)
      assert_receive {:agent_chat, _, {:message, %{role: :user, text: "first"}}}

      {:ok, :steered} = Chat.submit(ctx.conv, "redirect", delivery: :steer)

      # Not starting a turn is not the same as being invisible: it is still
      # something the operator said, and it belongs in the transcript.
      assert_receive {:agent_chat, _, {:message, %{role: :user, text: "redirect"}}}
    end
  end

  describe "status broadcasts" do
    test ":running is broadcast once per TURN, never on a steer" do
      ctx = start_chat()

      {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)
      assert_receive {:agent_chat, _, {:status, :running}}

      {:ok, :steered} = Chat.submit(ctx.conv, "redirect", delivery: :steer)

      # TradingLive hangs Chart Build's datareq budget refill off this broadcast
      # precisely because it fires once per turn start. A steer re-broadcasting
      # it would refill the brake on the turn it was meant to bound.
      refute_receive {:agent_chat, _, {:status, :running}}, 100
    end
  end
end
