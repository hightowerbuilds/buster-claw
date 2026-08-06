defmodule BusterClaw.Agent.FakeCodexTransport do
  @moduledoc """
  A stand-in for `ChatTransport.CodexAppServer`, for testing `Chat`'s behaviour
  with a **server-backed, turn-addressed** transport.

  It differs from `FakePersistentTransport` in the two ways that matter for
  Codex parity:

  * it holds a **thread id** on the handle from the first turn onward, the way a
    `thread/start` response does — which is what `Chat` reads instead of waiting
    for a notification that arrives too early to be routed;
  * it never spawns anything, because the real one shares a single connection
    across every conversation rather than owning a process per chat.

  `RACE` in the text makes `steer/3` answer `:no_active_turn`, standing in for
  codex's `-32600` refusal of a stale `expectedTurnId`.
  """

  @behaviour BusterClaw.Agent.ChatTransport

  alias BusterClaw.Agent.ChatTransport

  @impl true
  def open(opts), do: {:ok, ChatTransport.build(Keyword.get(opts, :agent, :codex), opts)}

  @impl true
  def capabilities,
    do: %{
      modes: [:start_turn, :queue_next, :steer, :interrupt],
      receipt: :turn_addressed,
      persistent: true
    }

  @impl true
  def start_turn(handle, _text) do
    handle = ensure_thread(handle)
    turn_id = "turn-#{System.unique_integer([:positive])}"
    {:ok, put_turn(handle, turn_id), turn_id}
  end

  @impl true
  def steer(handle, turn_ref, text) do
    cond do
      String.contains?(text, "RACE") -> {:error, :no_active_turn}
      current_turn(handle) != turn_ref -> {:error, :no_active_turn}
      true -> {:ok, handle, %{turn_id: turn_ref}}
    end
  end

  @impl true
  def interrupt(handle, _turn_ref), do: {:ok, %{handle | conn: conn_map(handle)}}

  @impl true
  def close(_handle), do: :ok

  # The thread id comes from the response to `thread/start` and then persists —
  # this is codex's conversation continuity, the thing `codex exec` could not do.
  defp ensure_thread(%{session_id: nil} = handle) do
    conn = Map.put(conn_map(handle), :registered?, true)
    thread = "thread-#{System.unique_integer([:positive])}"
    %{handle | session_id: thread, conn: conn, port: conn.ref}
  end

  defp ensure_thread(handle) do
    conn = Map.put(conn_map(handle), :registered?, true)
    %{handle | conn: conn, port: conn.ref}
  end

  defp conn_map(%{conn: %{} = conn}), do: conn
  defp conn_map(_handle), do: %{ref: make_ref(), turn_ref: nil, registered?: false}

  defp put_turn(handle, turn_id),
    do: %{handle | conn: Map.put(conn_map(handle), :turn_ref, turn_id)}

  defp current_turn(%{conn: %{turn_ref: ref}}), do: ref
  defp current_turn(_handle), do: nil
end
