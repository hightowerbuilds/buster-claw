defmodule BusterClaw.Agent.FakeOpenCodeTransport do
  @moduledoc """
  A stand-in for `ChatTransport.OpenCodeServer`, for testing `Chat`'s handling
  of the one backend that **cannot prove acceptance**.

  Markers in the text choose the outcome, so tests stay `async: true`:

  | text contains | `steer/3` answers | Chat reports |
  |---|---|---|
  | `"RACE"` | `{:error, :no_active_turn}` | `:queued`, at the front |
  | `"NORECEIPT"` | `{:ok, …, receipt: :unconfirmed}` | **`:sent`** |
  | anything else | `{:ok, …, receipt: :admission_event}` | `:steered` |

  The middle row is the point. OpenCode's `prompt_async` returns an empty body,
  so when the out-of-band echo does not arrive in time the message is in flight
  and unproven. It must NOT be re-queued (that would deliver the instruction
  twice) and it must NOT be called steered.
  """

  @behaviour BusterClaw.Agent.ChatTransport

  alias BusterClaw.Agent.ChatTransport

  @impl true
  def open(opts), do: {:ok, ChatTransport.build(Keyword.get(opts, :agent, :opencode), opts)}

  @impl true
  def capabilities,
    do: %{
      modes: [:start_turn, :queue_next, :steer, :interrupt],
      receipt: :admission_event,
      persistent: true
    }

  @impl true
  def start_turn(%{extra_cli_args: [_ | _]}, _text), do: {:error, :confinement_unsupported}

  def start_turn(handle, _text) do
    handle = ensure_session(handle)
    turn_ref = "msg_#{System.unique_integer([:positive])}"
    {:ok, put_turn(handle, turn_ref), turn_ref}
  end

  @impl true
  def steer(handle, turn_ref, text) do
    cond do
      String.contains?(text, "RACE") ->
        {:error, :no_active_turn}

      current_turn(handle) != turn_ref ->
        {:error, :no_active_turn}

      String.contains?(text, "NORECEIPT") ->
        {:ok, handle, %{message_id: "msg_x", receipt: :unconfirmed}}

      true ->
        {:ok, handle, %{message_id: "msg_x", receipt: :admission_event}}
    end
  end

  @impl true
  def interrupt(handle, _turn_ref), do: {:ok, handle}

  @impl true
  def close(_handle), do: :ok

  defp ensure_session(%{session_id: nil} = handle) do
    conn = conn_map(handle)

    %{
      handle
      | session_id: "ses_#{System.unique_integer([:positive])}",
        conn: conn,
        port: conn.ref
    }
  end

  defp ensure_session(handle) do
    conn = conn_map(handle)
    %{handle | conn: conn, port: conn.ref}
  end

  defp conn_map(%{conn: %{} = conn}), do: conn
  defp conn_map(_handle), do: %{ref: make_ref(), turn_ref: nil}

  defp put_turn(handle, turn_ref),
    do: %{handle | conn: Map.put(conn_map(handle), :turn_ref, turn_ref)}

  defp current_turn(%{conn: %{turn_ref: ref}}), do: ref
  defp current_turn(_handle), do: nil
end
