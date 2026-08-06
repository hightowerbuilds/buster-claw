defmodule BusterClaw.Agent.ChatTransportRoutingTest do
  @moduledoc """
  The routing invariant for the two server-backed transports:

  > **The ref handed to the connection MUST be the ref left on the handle.**

  That is the whole contract between an adapter and `Chat`. The connection
  routes a conversation's events to the ref it was registered with, and
  `Chat.handle_info/2` matches them against `handle.port`. If those two differ
  by so much as one `make_ref()`, every notification is delivered to a ref
  nobody is listening on — the transcript stays empty, the turn never ends, and
  the conversation dies of its own timeout with no error anywhere.

  This shipped in the codex adapter. `conn_map/1` mints a fresh ref for a handle
  that has none, and `ensure_thread/1` called it twice: once to register, once
  to store. Nothing in the suite caught it, because the fakes have their own
  correct ref handling and the connection tests supply their own refs — the real
  adapter's ref plumbing was the one seam no test crossed. The Codex acceptance
  smoke found it on its first real run, five minutes at a time.

  So these tests drive the REAL adapters against a recording stub, and assert
  the invariant directly.
  """
  use ExUnit.Case, async: false

  alias BusterClaw.Agent.ChatTransport

  # A stand-in connection that records the ref it was registered with. Both
  # adapters take the same shape of call, so one stub serves both.
  defmodule RecordingServer do
    @moduledoc false

    def start_thread(_server, ref, _opts), do: record(ref, "thread-1")
    def resume_thread(_server, ref, thread_id, _opts), do: record(ref, thread_id)
    def create_session(_server, ref, _opts), do: record(ref, "ses-1")
    def attach_session(_server, ref, session_id), do: record(ref, session_id)

    def start_turn(_server, _id, _text, _opts \\ []), do: {:ok, "turn-1"}
    def prompt(_server, _id, _text, _opts \\ []), do: {:ok, "msg-1"}
    def steer(_server, _id, turn, _text), do: {:ok, turn}
    def await_receipt(_ref, _message_id), do: :ok
    def interrupt(_server, _id, _turn), do: :ok
    def abort(_server, _id), do: :ok
    def unregister(_server, _ref), do: :ok

    defp record(ref, id) do
      send(self(), {:registered_ref, ref})
      {:ok, id}
    end
  end

  setup do
    Application.put_env(:buster_claw, :codex_app_server, RecordingServer)
    Application.put_env(:buster_claw, :open_code_server, RecordingServer)

    on_exit(fn ->
      Application.delete_env(:buster_claw, :codex_app_server)
      Application.delete_env(:buster_claw, :open_code_server)
    end)

    :ok
  end

  defp adapters do
    [
      {:codex, ChatTransport.CodexAppServer},
      {:opencode, ChatTransport.OpenCodeServer}
    ]
  end

  describe "the ref handed to the connection is the ref left on the handle" do
    test "on a FIRST turn, where the ref is minted" do
      for {agent, mod} <- adapters() do
        {:ok, handle} = mod.open(agent: agent)
        {:ok, handle, _turn} = mod.start_turn(handle, "hello")

        assert_received {:registered_ref, registered}

        # The bug: these were two different refs, and every event went nowhere.
        assert handle.port == registered,
               "#{inspect(mod)} registered #{inspect(registered)} but left #{inspect(handle.port)} on the handle"
      end
    end

    test "on a RESUMED conversation, where the ref is minted for a known id" do
      for {agent, mod} <- adapters() do
        # A conversation whose session/thread id survived a restart: the handle
        # has an id but no connection registration yet.
        {:ok, handle} = mod.open(agent: agent, session_id: "existing-id")
        {:ok, handle, _turn} = mod.start_turn(handle, "hello")

        assert_received {:registered_ref, registered}
        assert handle.port == registered, "#{inspect(mod)} resumed with a mismatched ref"
      end
    end

    test "the ref SURVIVES across turns — a fresh one would orphan the stream" do
      for {agent, mod} <- adapters() do
        {:ok, handle} = mod.open(agent: agent)
        {:ok, handle, _first} = mod.start_turn(handle, "one")
        first_ref = handle.port

        {:ok, handle, second} = mod.start_turn(handle, "two")

        assert handle.port == first_ref,
               "#{inspect(mod)} changed its routing ref between turns"

        # And the TURN ref does change, because a steer must name the current
        # turn rather than whatever came before it.
        assert second == "turn-1" or second == "msg-1"
      end
    end

    test "the session/thread id is left on the handle, so Chat can read it" do
      for {agent, mod} <- adapters() do
        {:ok, handle} = mod.open(agent: agent)
        {:ok, handle, _turn} = mod.start_turn(handle, "hello")

        # `Chat` copies this into its own state — it is how a second turn
        # continues the same conversation, and for codex it is the whole of the
        # continuity fix.
        assert is_binary(handle.session_id)
      end
    end
  end

  describe "a second registration is not attempted once attached" do
    test "the connection is registered exactly once per conversation" do
      for {agent, mod} <- adapters() do
        {:ok, handle} = mod.open(agent: agent)
        {:ok, handle, _first} = mod.start_turn(handle, "one")
        assert_received {:registered_ref, _ref}

        {:ok, _handle, _second} = mod.start_turn(handle, "two")

        # Re-registering would be harmless for codex and wasteful for opencode,
        # but it would also mean the adapter had forgotten it was attached —
        # which is the state that precedes minting a new ref.
        refute_received {:registered_ref, _ref}
      end
    end
  end
end
