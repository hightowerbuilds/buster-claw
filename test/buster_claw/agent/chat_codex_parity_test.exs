defmodule BusterClaw.Agent.ChatCodexParityTest do
  @moduledoc """
  Codex must behave the same as Claude through `Chat` — that is the product
  requirement, not an aspiration.

  This asserts the two things Codex chat did **not** have before Phase 3, both
  of which are the acceptance criterion for it:

  1. **Continuity.** Under `codex exec` every turn was a fresh process with no
     memory of the last, because `codex exec resume` is a subcommand
     `AgentBackend.argv/3` cannot express. A second turn must now continue the
     same thread.
  2. **Steering.** A message delivered into the turn already running.

  It runs against `FakeCodexTransport` rather than a real codex: what is under
  test is `Chat`'s behaviour given a `:turn_addressed`, persistent backend. The
  wire protocol is covered by `codex_app_server_test.exs` against a scripted
  server, and by the Phase 0 probe against the real one.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.ChatTransport
  alias BusterClaw.Agent.FakeCodexTransport
  alias BusterClaw.Agent.StreamEvent

  defp start_chat do
    parent = self()
    conv_id = "codex-#{System.unique_integer([:positive])}"
    Chat.subscribe(conv_id)

    {:ok, pid} =
      Chat.start_link(
        conv_id: conv_id,
        agent: :codex,
        transport_mod: FakeCodexTransport,
        spawner: fn _prompt, _opts ->
          send(parent, :spawned)
          {:ok, make_ref()}
        end,
        persist: false,
        audit: false
      )

    %{conv: conv_id, pid: pid}
  end

  # Feed a normalized event the way the app-server connection does.
  defp emit(ctx, event) do
    ref = :sys.get_state(ctx.pid).port
    send(ctx.pid, {:chat_event, ref, event})
    _ = :sys.get_state(ctx.pid)
    :ok
  end

  defp turn_completed, do: %StreamEvent{kind: :result, num_turns: 1, raw: %{}}

  describe "capability parity with Claude" do
    test "codex advertises steering, and the strongest receipt of the three" do
      caps = FakeCodexTransport.capabilities()

      assert :steer in caps.modes
      assert :queue_next in caps.modes
      assert :interrupt in caps.modes

      # `:turn_addressed` — `turn/steer` carries `expectedTurnId` and a stale id
      # is refused by the protocol. Claude's replay receipt cannot do that.
      assert caps.receipt == :turn_addressed
      assert caps.persistent
    end

    test "Chat reports codex as steerable, so the composer offers Steer now" do
      ctx = start_chat()
      assert :steer in Chat.capabilities(ctx.conv).modes
    end
  end

  describe "conversation continuity — the gap codex exec left" do
    test "a second turn continues the same thread instead of starting over" do
      ctx = start_chat()

      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)
      thread = :sys.get_state(ctx.pid).session_id
      assert is_binary(thread)

      emit(ctx, turn_completed())
      refute Chat.running?(ctx.conv)

      assert {:ok, :started} = Chat.submit(ctx.conv, "second", delivery: :auto)

      # The SAME thread. Under `codex exec` this was a brand new process with no
      # memory of "first", and the operator had no way to tell.
      assert :sys.get_state(ctx.pid).session_id == thread
    end

    test "the thread id is read from the handle, not from a racy notification" do
      ctx = start_chat()
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)

      # codex emits `thread/started` before the conversation can be registered
      # for it, so that notification is always dropped. Chat still knows the
      # thread — because the transport put it on the handle.
      state = :sys.get_state(ctx.pid)
      assert state.session_id == state.handle.session_id
    end

    test "no process is spawned per turn — the connection is shared" do
      ctx = start_chat()

      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)
      emit(ctx, turn_completed())
      assert {:ok, :started} = Chat.submit(ctx.conv, "second", delivery: :auto)

      refute_receive :spawned, 50
    end
  end

  describe "steering parity" do
    test "a message reaches the running turn and stays out of the queue" do
      ctx = start_chat()
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)

      assert {:ok, :steered} = Chat.submit(ctx.conv, "actually, do this", delivery: :steer)
      assert Chat.queue(ctx.conv) == []
      assert Chat.running?(ctx.conv)
    end

    test "the steered message is chipped as steered, exactly as on Claude" do
      ctx = start_chat()
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)
      assert_receive {:agent_chat, _, {:message, %{role: :user, text: "first"}}}

      assert {:ok, :steered} = Chat.submit(ctx.conv, "redirect", delivery: :steer)

      assert_receive {:agent_chat, _,
                      {:message, %{role: :user, text: "redirect", delivery: :steered}}}
    end

    test "a stale turn is refused by the protocol and demoted to the front" do
      ctx = start_chat()
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)
      assert {:ok, :queued} = Chat.submit(ctx.conv, "later, run the tests", delivery: :next)

      # `RACE` makes the fake answer `:no_active_turn`, which is what codex's
      # -32600 becomes. Unlike the other backends this is a PROTOCOL guarantee,
      # not something Buster Claw infers.
      assert {:ok, :queued} = Chat.submit(ctx.conv, "RACE late", delivery: :steer)
      assert [%{text: "RACE late"}, %{text: "later, run the tests"}] = Chat.queue(ctx.conv)
    end
  end

  describe "turn and transport boundaries" do
    test "turn/completed ends the turn and leaves the thread standing" do
      ctx = start_chat()
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)
      assert Chat.running?(ctx.conv)

      emit(ctx, turn_completed())

      refute Chat.running?(ctx.conv)
      # The transport is still there — a completed turn is not a closed thread.
      assert :sys.get_state(ctx.pid).handle != nil
    end

    test "a dropped connection fails the turn visibly and keeps the thread" do
      ctx = start_chat()
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)
      thread = :sys.get_state(ctx.pid).session_id

      ref = :sys.get_state(ctx.pid).port
      send(ctx.pid, {:chat_transport_down, ref, :app_server_exited})
      _ = :sys.get_state(ctx.pid)

      # Visible, not a hang.
      assert_receive {:agent_chat, _, {:message, %{role: :error, text: text}}}
      assert text =~ "connection dropped"
      refute Chat.running?(ctx.conv)

      # And recoverable: the thread id survives so the next message resumes.
      assert :sys.get_state(ctx.pid).session_id == thread
      assert {:ok, :started} = Chat.submit(ctx.conv, "again", delivery: :auto)
    end
  end

  describe "the normalizer speaks app-server, not exec" do
    test "an agentMessage item becomes assistant text" do
      event =
        StreamEvent.normalize(:codex_app_server, %{
          "method" => "item/completed",
          "params" => %{"item" => %{"type" => "agentMessage", "text" => "on it"}}
        })

      assert %StreamEvent{kind: :assistant_text, text: "on it"} = event
    end

    test "a commandExecution reports when it STARTS, so work is visible in flight" do
      event =
        StreamEvent.normalize(:codex_app_server, %{
          "method" => "item/started",
          "params" => %{"item" => %{"type" => "commandExecution", "command" => "ls -la"}}
        })

      assert %StreamEvent{kind: :tool_use, tool: "command_execution", summary: summary} = event
      assert summary =~ "ls -la"
    end

    test "agentMessage DELTAS are ignored, so the transcript is not one row per token" do
      # Coalescing by construction: the completed item carries the whole text.
      event =
        StreamEvent.normalize(:codex_app_server, %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => "on", "itemId" => "msg_1"}
        })

      assert %StreamEvent{kind: :unknown} = event
    end

    test "token usage is taken per-TURN, not the thread's running total" do
      # The same distinction that made claude's cumulative cost a bug.
      event =
        StreamEvent.normalize(:codex_app_server, %{
          "method" => "thread/tokenUsage/updated",
          "params" => %{
            "tokenUsage" => %{
              "last" => %{"inputTokens" => 10, "outputTokens" => 2, "cachedInputTokens" => 1},
              "total" => %{"inputTokens" => 999, "outputTokens" => 999}
            }
          }
        })

      assert %StreamEvent{kind: :usage, usage: usage} = event
      assert usage.input_tokens == 10
      assert usage.output_tokens == 2

      # No dollar figure: codex reports tokens only, and this app owns no price
      # table — a computed cost would be a number the operator trusts and we
      # invented.
      assert usage.cost_usd == nil
    end

    test "a failed turn carries its error message into the transcript" do
      event =
        StreamEvent.normalize(:codex_app_server, %{
          "method" => "turn/completed",
          "params" => %{"turn" => %{"error" => %{"message" => "model refused"}}}
        })

      assert %StreamEvent{kind: :result, text: "model refused"} = event
    end

    test "exec-shaped events are NOT read as app-server ones" do
      # Same concepts, different spelling (`item.completed` / `agent_message`
      # vs `item/completed` / `agentMessage`). Two normalizers, on purpose.
      assert %StreamEvent{kind: :unknown} =
               StreamEvent.normalize(:codex_app_server, %{
                 "type" => "item.completed",
                 "item" => %{"type" => "agent_message", "text" => "hi"}
               })
    end
  end

  describe "the turn's meta line" do
    test "a codex turn reports TOKENS, because codex reports no cost" do
      ctx = start_chat()
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)

      # Codex delivers usage in its own notification, BEFORE the result and not
      # on it. Chat used to drop that event entirely, so a codex turn completed
      # with no meta line at all while a claude turn reported its cost — a
      # parity gap the acceptance smoke surfaced as `turns completed: 0`.
      emit(ctx, %StreamEvent{
        kind: :usage,
        usage: %{
          input_tokens: 15_804,
          output_tokens: 122,
          cache_read_tokens: 11_008,
          cache_write_tokens: 0,
          cost_usd: nil
        }
      })

      emit(ctx, turn_completed())

      assert_receive {:agent_chat, _, {:message, %{role: :meta, text: text}}}
      assert text =~ "1 turns"
      assert text =~ "15.9k tokens"

      # And no invented dollar figure: this app owns no price table.
      refute text =~ "$"
    end

    test "a turn with neither cost nor tokens still ends, it just says less" do
      ctx = start_chat()
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)

      emit(ctx, turn_completed())

      # The turn must END regardless — a missing meta line is cosmetic, a turn
      # that never completes is the conversation hanging until its timeout.
      refute Chat.running?(ctx.conv)
    end
  end

  describe "model resolution" do
    test "a codex conversation is given a CODEX model, not the global backend's" do
      # `ModelPolicy.for_surface/1` resolves the backend from global policy,
      # which is not necessarily the backend a conversation is running. Handing
      # a claude model id to codex is not a degraded outcome — codex rejects it,
      # and model strings are only meaningful inside their own namespace.
      ctx = start_chat()
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)

      model = :sys.get_state(ctx.pid).handle.model

      # Nothing is configured in this test env, so the honest answer is nil —
      # omit the field and leave the CLI's own default in charge. What must NOT
      # happen is a claude id leaking through.
      refute is_binary(model) and String.starts_with?(model, "claude-")
    end
  end

  describe "confinement translation" do
    test "the handle's permission mode becomes codex's sandbox enum, not a widening" do
      # `bypassPermissions` deliberately does NOT become `danger-full-access`:
      # on claude it waives the prompt while the allowlist still binds, whereas
      # danger-full-access waives the sandbox itself.
      assert ChatTransport.build(:codex, permission_mode: "dontAsk").permission_mode == "dontAsk"

      assert ChatTransport.build(:codex, permission_mode: "bypassPermissions").permission_mode ==
               "bypassPermissions"
    end
  end
end
