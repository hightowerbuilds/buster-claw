defmodule BusterClaw.Agent.ChatTransport.OpenCodeServer do
  @moduledoc """
  Chat transport for OpenCode over `opencode serve`.

  The third of the three, and the one whose honesty problem is sharpest. Phase 0
  proved OpenCode **does** steer — a prompt submitted to a busy session
  redirected the active run, with exactly one `session.idle` at the end. But it
  offers no receipt in the HTTP response: `prompt_async` answers with an **empty
  body**.

  ## Why `steer/3` waits

  A 2xx with nothing in it says the server took the request. It does not say the
  message was admitted to the session. Phase 0 found the real evidence: an SSE
  `message.updated` for our own `messageID`, ~20ms later.

  So this adapter supplies the id, posts, and then waits for that echo before
  reporting success. Three outcomes, all distinct on purpose:

  | | reported | meaning |
  |---|---|---|
  | echo arrives | `:steered` | the session admitted it into the running turn |
  | echo times out | `:sent` | it is in flight and we cannot prove it landed |
  | POST fails | `{:error, …}` | it never left |

  **The timeout must not be treated as a failure.** The message was posted;
  re-queueing it would deliver it twice. `:sent` exists precisely so the UI can
  be truthful about the one case where we genuinely do not know.

  ## Confinement is refused, not degraded

  Phase 0: a session naming a nonexistent agent file is accepted, echoes the
  bogus name back on create *and* re-fetch, then admits a prompt. The server API
  is strictly worse than the CLI, which at least prints the stderr line
  `AgentBackend.fallback_warning?/2` scrapes.

  So a confined OpenCode chat is **refused** rather than run unconfined.
  `Chat.effective_agent/1` already pins any conversation carrying confinement
  flags to claude, so this is a second lock on a door that should already be
  shut — which is the right number of locks for a control whose failure mode is
  silent `{"*", allow, "*"}`.

  ## v1, and why

  The v2 API models `delivery: "steer" | "queue"` natively with a proper receipt
  and **does not execute** — it parks the prompt awaiting a driver we are not.
  v1 is the only path that runs. Worth re-checking on every opencode upgrade.
  """

  @behaviour BusterClaw.Agent.ChatTransport

  require Logger

  alias BusterClaw.Agent.ChatTransport
  alias BusterClaw.Agent.OpenCodeServer

  @impl true
  def open(opts), do: {:ok, ChatTransport.build(Keyword.get(opts, :agent, :opencode), opts)}

  @impl true
  def capabilities do
    %{
      modes: [:start_turn, :queue_next, :steer, :interrupt],
      # The weakest of the three receipts, and named honestly: it proves the
      # session ADMITTED the message, arriving out of band ~20ms after a POST
      # that said nothing at all.
      receipt: :admission_event,
      persistent: true
    }
  end

  @impl true
  def start_turn(handle, text) do
    with {:ok, handle} <- ensure_session(handle),
         {:ok, message_id} <-
           server().prompt(server(), handle.session_id, text, model: handle.model) do
      {:ok, put_turn(handle, message_id), message_id}
    end
  end

  @impl true
  def steer(handle, turn_ref, text) do
    cond do
      is_nil(handle.session_id) ->
        {:error, :no_active_turn}

      current_turn(handle) != turn_ref ->
        {:error, :no_active_turn}

      true ->
        deliver(handle, text)
    end
  end

  @impl true
  def interrupt(handle, _turn_ref) do
    if handle.session_id, do: server().abort(server(), handle.session_id)
    {:ok, handle}
  end

  @impl true
  def close(handle) do
    # The SESSION is not deleted, only our interest in it — a reopened tab
    # continues where it left off.
    if ref(handle), do: server().unregister(server(), ref(handle))
    :ok
  end

  # --- delivery ------------------------------------------------------------

  defp deliver(handle, text) do
    case server().prompt(server(), handle.session_id, text) do
      {:ok, message_id} ->
        case server().await_receipt(ref(handle), message_id) do
          :ok ->
            {:ok, handle, %{message_id: message_id, receipt: :admission_event}}

          {:error, :timeout} ->
            # Posted but unproven. NOT an error: re-queueing would deliver the
            # same instruction twice, which is worse than an honest "sent".
            Logger.warning("OpenCode: no admission receipt for #{message_id} within the window")
            {:ok, handle, %{message_id: message_id, receipt: :unconfirmed}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- session lifecycle ---------------------------------------------------

  defp ensure_session(%{extra_cli_args: [_ | _]} = _handle) do
    # A conversation carrying confinement flags must never reach opencode. It
    # should already be impossible — `Chat.effective_agent/1` pins those to
    # claude — so this is the second lock, and it fails loudly rather than
    # running the conversation with everything allowed.
    {:error, :confinement_unsupported}
  end

  defp ensure_session(%{session_id: nil} = handle) do
    conn = new_conn(handle)

    case server().create_session(server(), conn.ref, []) do
      {:ok, session_id} ->
        {:ok, %{handle | session_id: session_id, conn: attached(conn), port: conn.ref}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_session(handle) do
    if attached?(handle) do
      {:ok, handle}
    else
      conn = new_conn(handle)

      case server().attach_session(server(), conn.ref, handle.session_id) do
        {:ok, _id} -> {:ok, %{handle | conn: attached(conn), port: conn.ref}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # --- handle plumbing -----------------------------------------------------

  defp new_conn(%{conn: %{} = conn}), do: conn
  defp new_conn(_handle), do: %{ref: make_ref(), turn_ref: nil, attached?: false}

  defp attached(conn), do: Map.put(conn, :attached?, true)
  defp attached?(%{conn: %{attached?: true}}), do: true
  defp attached?(_handle), do: false

  defp ref(%{conn: %{ref: ref}}), do: ref
  defp ref(_handle), do: nil

  defp put_turn(handle, turn_ref),
    do: %{handle | conn: Map.put(new_conn(handle), :turn_ref, turn_ref) |> attached()}

  defp current_turn(%{conn: %{turn_ref: ref}}), do: ref
  defp current_turn(_handle), do: nil

  # Injectable for the same reason as the codex adapter's: without it the ref
  # plumbing is unreachable from the suite.
  defp server, do: Application.get_env(:buster_claw, :open_code_server, OpenCodeServer)
end
