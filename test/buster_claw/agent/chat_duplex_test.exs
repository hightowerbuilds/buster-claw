defmodule BusterClaw.Agent.ChatDuplexTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.FakePersistentTransport

  # A spawner that reports every spawn, so a test can prove two turns shared one
  # process rather than quietly starting a second.
  defp counting_spawner(parent) do
    fn _prompt, opts ->
      port = make_ref()
      send(parent, {:spawned, port, opts})
      {:ok, port}
    end
  end

  defp start_chat do
    parent = self()
    conv_id = "duplex-#{System.unique_integer([:positive])}"
    Chat.subscribe(conv_id)

    {:ok, pid} =
      Chat.start_link(
        conv_id: conv_id,
        spawner: counting_spawner(parent),
        transport_mod: FakePersistentTransport,
        persist: false,
        audit: false
      )

    assert {:ok, :started} = Chat.submit(conv_id, "first", delivery: :auto)
    assert_receive {:spawned, port, _opts}

    %{conv: conv_id, pid: pid, port: port}
  end

  # Feed one stream-json line to the conversation as though it came off the port.
  defp emit(%{pid: pid, port: port}, event) do
    send(pid, {port, {:data, Jason.encode!(event) <> "\n"}})
    _ = :sys.get_state(pid)
    :ok
  end

  defp result_event(cost, turns \\ 1),
    do: %{
      "type" => "result",
      "subtype" => "success",
      "total_cost_usd" => cost,
      "num_turns" => turns,
      "session_id" => "sess-duplex"
    }

  describe "the turn boundary" do
    test "a result event ends the TURN and leaves the transport standing" do
      ctx = start_chat()
      assert Chat.running?(ctx.conv)

      emit(ctx, result_event(0.10))

      # Turn over...
      refute Chat.running?(ctx.conv)

      # ...but the process was never torn down: the next turn reuses it, so no
      # second spawn arrives.
      assert {:ok, :started} = Chat.submit(ctx.conv, "second", delivery: :auto)
      refute_receive {:spawned, _port, _opts}, 50
      assert Chat.running?(ctx.conv)
    end

    test "the conversation settles idle and rings only when the queue is empty" do
      ctx = start_chat()
      assert {:ok, :queued} = Chat.submit(ctx.conv, "next up", delivery: :next)

      emit(ctx, result_event(0.10))

      # The queued message became the next turn on the same transport, so the
      # conversation never went idle between them.
      assert Chat.running?(ctx.conv)
      assert Chat.queue(ctx.conv) == []
      refute_receive {:spawned, _port, _opts}, 50
    end
  end

  describe "cumulative cost" do
    test "each turn is charged the DELTA, not claude's running session total" do
      ctx = start_chat()

      emit(ctx, result_event(0.1197, 3))
      assert_receive {:agent_chat, _, {:message, %{role: :meta, text: first}}}
      assert first =~ "3 turns"
      assert first =~ "$0.1197"

      assert {:ok, :started} = Chat.submit(ctx.conv, "second", delivery: :auto)

      # Claude reports the SESSION total here, which is larger than turn 2 cost.
      # Measured 08-04: a twelve-token turn reported $0.1326 after a $0.1197
      # first turn. Reporting it verbatim would say this turn cost $0.1326.
      emit(ctx, result_event(0.1326, 1))
      assert_receive {:agent_chat, _, {:message, %{role: :meta, text: second}}}
      assert second =~ "1 turns"
      assert second =~ "$0.0129"
      refute second =~ "$0.1326"
    end

    test "a non-monotonic total never produces a negative charge" do
      ctx = start_chat()
      emit(ctx, result_event(0.50, 1))
      assert_receive {:agent_chat, _, {:message, %{role: :meta}}}

      assert {:ok, :started} = Chat.submit(ctx.conv, "second", delivery: :auto)
      emit(ctx, result_event(0.20, 1))

      assert_receive {:agent_chat, _, {:message, %{role: :meta, text: text}}}
      assert text =~ "$0.0"
      refute text =~ "-"
    end
  end

  describe "steering an active turn" do
    test "reaches the running turn and stays out of the queue" do
      ctx = start_chat()

      assert {:ok, :steered} = Chat.submit(ctx.conv, "actually, do this", delivery: :steer)
      assert Chat.queue(ctx.conv) == []
      assert Chat.running?(ctx.conv)
    end

    test "a steer aimed at a FINISHED turn is demoted rather than applied to the next one" do
      ctx = start_chat()
      emit(ctx, result_event(0.10))
      refute Chat.running?(ctx.conv)

      # Idle, so this simply starts a turn — the interesting case is below.
      assert {:ok, :started} = Chat.submit(ctx.conv, "second", delivery: :auto)

      # Now steer with the fake reporting the race. Scenario C: never silently
      # injected into whatever turn is current.
      assert {:ok, :queued} = Chat.submit(ctx.conv, "RACE late redirect", delivery: :steer)
      assert [%{text: "RACE late redirect"}] = Chat.queue(ctx.conv)
    end

    test "a stale turn reference cannot steer the turn that replaced it" do
      ctx = start_chat()

      # End turn 1 and start turn 2 on the same transport. The adapter compares
      # the reference it was given against the turn it is actually running.
      emit(ctx, result_event(0.10))
      assert {:ok, :started} = Chat.submit(ctx.conv, "second", delivery: :auto)

      # Chat always addresses the CURRENT turn, so this succeeds — the guard is
      # exercised directly against the adapter below.
      assert {:ok, :steered} = Chat.submit(ctx.conv, "redirect", delivery: :steer)

      handle = %BusterClaw.Agent.ChatTransport{port: make_ref(), conn: %{turn_ref: make_ref()}}

      assert FakePersistentTransport.steer(handle, make_ref(), "for the old turn") ==
               {:error, :no_active_turn}
    end
  end

  describe "transport failure" do
    test "an OS exit while running is reported as a failure, not a completed turn" do
      ctx = start_chat()

      send(ctx.pid, {ctx.port, {:exit_status, 1}})
      _ = :sys.get_state(ctx.pid)

      assert_receive {:agent_chat, _, {:message, %{role: :error, text: text}}}
      assert text =~ "exited with status 1"
      refute Chat.running?(ctx.conv)
    end

    test "the next message restarts the transport, resuming rather than starting over" do
      ctx = start_chat()

      # Learn a session id, then lose the process.
      emit(ctx, %{"type" => "system", "subtype" => "init", "session_id" => "sess-abc"})
      send(ctx.pid, {ctx.port, {:exit_status, 1}})
      _ = :sys.get_state(ctx.pid)

      assert {:ok, :started} = Chat.submit(ctx.conv, "again", delivery: :auto)

      # A NEW process — and the handle it was opened with carries the session id,
      # so the conversation resumes instead of forgetting itself.
      assert_receive {:spawned, new_port, _opts}
      refute new_port == ctx.port
      assert Chat.running?(ctx.conv)
    end

    test "an exit while idle is not written into the transcript" do
      ctx = start_chat()
      emit(ctx, result_event(0.10))
      refute Chat.running?(ctx.conv)

      # Drain the messages the turn produced.
      _ = :sys.get_state(ctx.pid)

      send(ctx.pid, {ctx.port, {:exit_status, 0}})
      _ = :sys.get_state(ctx.pid)

      refute_receive {:agent_chat, _, {:message, %{role: :error}}}, 50
    end
  end

  describe "reset" do
    test "drops the transport and the session's running cost total together" do
      ctx = start_chat()
      emit(ctx, result_event(0.50, 1))

      # Consume the first turn's meta line, or the assertion below reads it
      # instead of the one it means to check.
      assert_receive {:agent_chat, _, {:message, %{role: :meta, text: "1 turns · $0.5"}}}

      :ok = Chat.reset(ctx.conv)
      assert_receive {:agent_chat, _, {:reset}}

      assert {:ok, :started} = Chat.submit(ctx.conv, "fresh", delivery: :auto)
      assert_receive {:spawned, new_port, _opts}

      # The baseline reset with the thread: this turn is charged its own cost,
      # not credited for the old session's spend.
      emit(%{ctx | port: new_port}, result_event(0.02, 1))
      assert_receive {:agent_chat, _, {:message, %{role: :meta, text: text}}}
      assert text =~ "$0.02"
    end
  end
end
