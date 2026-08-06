defmodule BusterClaw.Agent.FakePersistentTransport do
  @moduledoc """
  A `ChatTransport` that outlives its turns, for testing `Chat`'s duplex
  lifecycle without a real OS process.

  It exists because the interesting Phase 2 behaviour is not "does claude
  accept JSONL" — that was measured by `scripts/probe_claude_duplex.exs` — but
  what `Chat` concludes from the two things it observes once a transport is
  persistent:

  * a `result` event ends the **turn** and must NOT tear down the transport;
  * an OS exit is a **transport failure**, not a completed turn.

  Both were previously the same event, and getting them backwards either hangs
  a conversation on a turn that finished or reports a crash as success.

  `start_turn/2` spawns through the injected `:spawner` only on the first call
  and reuses the handle's port afterwards, so a test can assert that two turns
  shared one process by counting spawns. Steering follows the same
  marker-in-the-text convention as `BusterClaw.Agent.FakeChatTransport`, plus
  the turn-reference check that a duplex transport genuinely needs.
  """

  @behaviour BusterClaw.Agent.ChatTransport

  alias BusterClaw.Agent.ChatTransport

  @impl true
  def open(opts), do: {:ok, ChatTransport.build(Keyword.get(opts, :agent), opts)}

  @impl true
  def capabilities,
    do: %{
      modes: [:start_turn, :queue_next, :steer, :interrupt],
      receipt: :boundary_replay,
      persistent: true
    }

  @impl true
  def start_turn(handle, text) do
    case ensure_port(handle) do
      {:ok, handle} ->
        turn_ref = make_ref()
        send_text(handle, text)
        {:ok, %{handle | conn: %{turn_ref: turn_ref}}, turn_ref}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def steer(handle, turn_ref, text) do
    cond do
      String.contains?(text, "RACE") -> {:error, :no_active_turn}
      current_turn(handle) != turn_ref -> {:error, :no_active_turn}
      true -> {:ok, handle, %{turn_ref: turn_ref}}
    end
  end

  @impl true
  def interrupt(handle, _turn_ref), do: {:ok, %{handle | port: nil, conn: nil}}

  @impl true
  def close(_handle), do: :ok

  # The whole point: a second turn must NOT spawn again.
  defp ensure_port(%{port: port} = handle) when not is_nil(port), do: {:ok, handle}

  defp ensure_port(handle) do
    case handle.spawner.("", duplex: true, agent: handle.agent) do
      {:ok, port} -> {:ok, %{handle | port: port}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Report what was written so a test can assert on delivery without a pipe.
  defp send_text(handle, text) do
    case handle.conn do
      %{reporter: pid} when is_pid(pid) -> send(pid, {:written, text})
      _ -> :ok
    end
  end

  defp current_turn(%{conn: %{turn_ref: ref}}), do: ref
  defp current_turn(_handle), do: nil
end
