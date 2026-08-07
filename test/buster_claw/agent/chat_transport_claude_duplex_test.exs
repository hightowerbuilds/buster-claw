defmodule BusterClaw.Agent.ChatTransportClaudeDuplexTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Agent.ChatTransport.ClaudeDuplex

  # A real pipe, because the interesting part of this adapter is the part the
  # fakes cannot reach: `Port.command/2` writing JSONL to a live stdin, and
  # `Port.info/1` telling a dead process from a live one. `cat` echoes whatever
  # we write straight back, which stands in nicely for `--replay-user-messages`.
  defp cat_spawner(parent) do
    fn _prompt, opts ->
      port =
        Port.open({:spawn_executable, "/bin/cat"}, [:binary, :exit_status, :hide, {:args, []}])

      send(parent, {:spawned, port, opts})
      {:ok, port}
    end
  end

  defp open_handle(opts \\ []) do
    {:ok, handle} =
      ClaudeDuplex.open(Keyword.merge([agent: :claude, spawner: cat_spawner(self())], opts))

    handle
  end

  # The next full line the child echoed back.
  defp echoed do
    receive do
      {_port, {:data, data}} -> data |> String.split("\n", trim: true) |> List.first()
    after
      2000 -> flunk("nothing came back off the pipe")
    end
  end

  describe "start_turn/2" do
    test "spawns once and writes the first message as JSONL on stdin" do
      handle = open_handle()

      assert {:ok, handle, turn_ref} = ClaudeDuplex.start_turn(handle, "hello there")
      assert_receive {:spawned, port, opts}
      assert handle.port == port
      assert is_reference(turn_ref)

      # Duplex is requested at the spawn, which is what routes `Chat`'s default
      # spawner to the stdin-preserving opener.
      assert Keyword.fetch!(opts, :duplex)
      assert Keyword.fetch!(opts, :stream)

      # No positional prompt is passed — the message goes down the pipe.
      assert Jason.decode!(echoed()) == %{
               "type" => "user",
               "message" => %{"role" => "user", "content" => "hello there"}
             }

      ClaudeDuplex.close(handle)
    end

    test "a SECOND turn reuses the same process — that is the whole point" do
      handle = open_handle()

      assert {:ok, handle, first} = ClaudeDuplex.start_turn(handle, "one")
      assert_receive {:spawned, _port, _opts}
      _ = echoed()

      assert {:ok, handle, second} = ClaudeDuplex.start_turn(handle, "two")
      refute_receive {:spawned, _port, _opts}, 50

      # A new turn reference each time, so a steer can name the right one.
      refute first == second
      assert get_in(Jason.decode!(echoed()), ["message", "content"]) == "two"

      ClaudeDuplex.close(handle)
    end

    test "respawns after the process dies, carrying the session id for --resume" do
      handle = open_handle(session_id: "sess-xyz")

      assert {:ok, handle, _ref} = ClaudeDuplex.start_turn(handle, "one")
      assert_receive {:spawned, first_port, first_opts}
      assert ["--resume", "sess-xyz" | _contract] = Keyword.fetch!(first_opts, :extra_args)
      _ = echoed()

      # Lose the process the way a crash would.
      Port.close(first_port)

      assert {:ok, handle, _ref} = ClaudeDuplex.start_turn(handle, "two")
      assert_receive {:spawned, second_port, second_opts}
      refute second_port == first_port

      # Resumed, not restarted from nothing: a transport failure costs the turn,
      # not the conversation. The tail is the attention contract, which every
      # steerable transport carries — see `AttentionContractTest`.
      assert ["--resume", "sess-xyz" | _contract] = Keyword.fetch!(second_opts, :extra_args)

      ClaudeDuplex.close(handle)
    end
  end

  describe "steer/3" do
    test "writes into the live turn when the reference matches" do
      handle = open_handle()
      assert {:ok, handle, turn_ref} = ClaudeDuplex.start_turn(handle, "first")
      assert_receive {:spawned, _port, _opts}
      _ = echoed()

      assert {:ok, _handle, _receipt} = ClaudeDuplex.steer(handle, turn_ref, "actually, stop")
      assert get_in(Jason.decode!(echoed()), ["message", "content"]) == "actually, stop"

      ClaudeDuplex.close(handle)
    end

    test "refuses a stale turn reference rather than steering the current turn" do
      handle = open_handle()
      assert {:ok, handle, _first} = ClaudeDuplex.start_turn(handle, "one")
      assert_receive {:spawned, _port, _opts}
      _ = echoed()

      assert {:ok, handle, _second} = ClaudeDuplex.start_turn(handle, "two")
      _ = echoed()

      # Scenario C: the operator aimed at a turn that has since ended. Applying
      # this to the turn that replaced it is the failure mode the whole
      # expected-turn-id design exists to prevent.
      assert ClaudeDuplex.steer(handle, make_ref(), "for the old turn") ==
               {:error, :no_active_turn}

      ClaudeDuplex.close(handle)
    end

    test "refuses when the process is gone" do
      handle = open_handle()
      assert {:ok, handle, turn_ref} = ClaudeDuplex.start_turn(handle, "one")
      assert_receive {:spawned, port, _opts}
      _ = echoed()

      Port.close(port)

      assert ClaudeDuplex.steer(handle, turn_ref, "too late") == {:error, :no_active_turn}
    end

    test "refuses an oversized message before it reaches the pipe" do
      handle = open_handle()
      assert {:ok, handle, turn_ref} = ClaudeDuplex.start_turn(handle, "one")
      assert_receive {:spawned, _port, _opts}
      _ = echoed()

      big = String.duplicate("x", BusterClaw.Agent.ChatMessageEncoder.max_bytes() + 1)

      # A partial write would desynchronise claude's JSONL parser for the rest of
      # the conversation — far worse than a refused message.
      assert {:error, {:too_large, _size, _limit}} = ClaudeDuplex.steer(handle, turn_ref, big)

      ClaudeDuplex.close(handle)
    end
  end

  describe "capabilities/0" do
    test "advertises steering, a boundary receipt, and a persistent transport" do
      caps = ClaudeDuplex.capabilities()

      assert :steer in caps.modes
      assert :queue_next in caps.modes

      # `:boundary_replay`, not something stronger: the receipt arrives when the
      # in-flight tool ends, and it proves the harness ACCEPTED the message — not
      # that the model has read that sentence.
      assert caps.receipt == :boundary_replay
      assert caps.persistent
    end
  end
end
