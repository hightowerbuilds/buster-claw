defmodule BusterClaw.Agent.ChatOpenCodeParityTest do
  @moduledoc """
  OpenCode's behaviour through `Chat`, and the one place it legitimately differs
  from the other two.

  Parity means OpenCode steers like Claude and Codex do — measured in Phase 0,
  and asserted here. It does **not** mean pretending OpenCode can prove things
  it cannot. `prompt_async` returns an empty body, so when the out-of-band
  acceptance echo does not arrive the honest report is `:sent`, not `:steered`.
  That distinction is the substance of this file.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.FakeOpenCodeTransport
  alias BusterClaw.Agent.StreamEvent

  defp start_chat(opts \\ []) do
    conv_id = "oc-#{System.unique_integer([:positive])}"
    Chat.subscribe(conv_id)

    {:ok, pid} =
      Chat.start_link(
        [
          conv_id: conv_id,
          agent: :opencode,
          transport_mod: FakeOpenCodeTransport,
          spawner: fn _p, _o -> {:ok, make_ref()} end,
          persist: false,
          audit: false
        ] ++ opts
      )

    %{conv: conv_id, pid: pid}
  end

  defp emit(ctx, event) do
    send(ctx.pid, {:chat_event, :sys.get_state(ctx.pid).port, event})
    _ = :sys.get_state(ctx.pid)
    :ok
  end

  describe "parity with the other two" do
    test "opencode steers, and Chat reports it as steerable" do
      ctx = start_chat()

      assert :steer in Chat.capabilities(ctx.conv).modes
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)
      assert {:ok, :steered} = Chat.submit(ctx.conv, "redirect", delivery: :steer)
      assert Chat.queue(ctx.conv) == []
    end

    test "a session persists across turns, so no second one is created" do
      ctx = start_chat()

      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)
      session = :sys.get_state(ctx.pid).session_id
      assert is_binary(session)

      emit(ctx, %StreamEvent{kind: :result, cost_usd: 0.01, num_turns: 1})
      assert {:ok, :started} = Chat.submit(ctx.conv, "second", delivery: :auto)

      assert :sys.get_state(ctx.pid).session_id == session
    end

    test "session.idle ends the turn and carries the turn's cost" do
      ctx = start_chat()
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)

      emit(ctx, %StreamEvent{kind: :result, cost_usd: 0.0135, num_turns: 1})

      refute Chat.running?(ctx.conv)
      assert_receive {:agent_chat, _, {:message, %{role: :meta, text: text}}}
      assert text =~ "$0.0135"
    end
  end

  describe "the honest gap: acceptance cannot always be proven" do
    test "an unconfirmed delivery is reported as :sent, NOT :steered" do
      ctx = start_chat()
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)

      assert {:ok, :sent} = Chat.submit(ctx.conv, "NORECEIPT redirect", delivery: :steer)
    end

    test "an unconfirmed delivery is NOT re-queued — that would send it twice" do
      ctx = start_chat()
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)
      assert {:ok, :sent} = Chat.submit(ctx.conv, "NORECEIPT redirect", delivery: :steer)

      # The message was posted. Putting it back in the queue would deliver the
      # same instruction a second time, which is worse than an honest "sent".
      assert Chat.queue(ctx.conv) == []
    end

    test "the bubble is chipped SENT, so the UI cannot overstate it" do
      ctx = start_chat()
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)
      assert_receive {:agent_chat, _, {:message, %{role: :user, text: "first"}}}

      assert {:ok, :sent} = Chat.submit(ctx.conv, "NORECEIPT redirect", delivery: :steer)

      assert_receive {:agent_chat, _, {:message, %{role: :user, delivery: :sent}}}
    end

    test "a CONFIRMED delivery still gets the full :steered claim" do
      ctx = start_chat()
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)

      assert {:ok, :steered} = Chat.submit(ctx.conv, "redirect", delivery: :steer)
      assert_receive {:agent_chat, _, {:message, %{role: :user, delivery: :steered}}}
    end

    test "the race is still a race, and still goes to the front of the queue" do
      ctx = start_chat()
      assert {:ok, :started} = Chat.submit(ctx.conv, "first", delivery: :auto)
      assert {:ok, :queued} = Chat.submit(ctx.conv, "later", delivery: :next)

      assert {:ok, :queued} = Chat.submit(ctx.conv, "RACE late", delivery: :steer)
      assert [%{text: "RACE late"}, %{text: "later"}] = Chat.queue(ctx.conv)
    end
  end

  describe "confinement is refused, not degraded" do
    test "a conversation carrying confinement flags never reaches opencode" do
      # `Chat.effective_agent/1` already pins these to claude, so reaching the
      # transport at all would be a bug. This is the second lock: the transport
      # refuses rather than running with `{\"*\", allow, \"*\"}`.
      ctx = start_chat(extra_cli_args: ["--strict-mcp-config"])

      # effective_agent pinned it to claude, so the fake opencode transport is
      # still selected by `transport_mod` — and refuses.
      assert {:error, :confinement_unsupported} =
               Chat.submit(ctx.conv, "read my positions", delivery: :auto)

      refute Chat.running?(ctx.conv)
    end
  end

  describe "the server-mode normalizer" do
    test "an assistant text part becomes assistant text" do
      event =
        StreamEvent.normalize(:opencode_server, %{
          "type" => "part",
          "role" => "assistant",
          "part" => %{"type" => "text", "text" => "on it"}
        })

      assert %StreamEvent{kind: :assistant_text, text: "on it"} = event
    end

    test "a running tool is tool_use; a completed one is tool_result" do
      running =
        StreamEvent.normalize(:opencode_server, %{
          "type" => "part",
          "role" => "assistant",
          "part" => %{
            "type" => "tool",
            "tool" => "bash",
            "state" => %{"status" => "running", "input" => %{"command" => "ls"}}
          }
        })

      assert %StreamEvent{kind: :tool_use, tool: "bash", summary: summary} = running
      assert summary =~ "ls"

      completed =
        StreamEvent.normalize(:opencode_server, %{
          "type" => "part",
          "role" => "assistant",
          "part" => %{"type" => "tool", "tool" => "bash", "state" => %{"status" => "completed"}}
        })

      assert %StreamEvent{kind: :tool_result} = completed
    end

    test "a USER part is ignored, so the operator's message is not doubled" do
      event =
        StreamEvent.normalize(:opencode_server, %{
          "type" => "part",
          "role" => "user",
          "part" => %{"type" => "text", "text" => "what I typed"}
        })

      assert %StreamEvent{kind: :unknown} = event
    end

    test "run-mode events are NOT read as server-mode ones" do
      # A third opencode shape, distinct from `run --format json`. Two
      # normalizers, deliberately.
      assert %StreamEvent{kind: :unknown} =
               StreamEvent.normalize(:opencode_server, %{
                 "type" => "text",
                 "part" => %{"text" => "hi"}
               })
    end
  end
end
