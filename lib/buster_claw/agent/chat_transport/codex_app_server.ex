defmodule BusterClaw.Agent.ChatTransport.CodexAppServer do
  @moduledoc """
  Chat transport for Codex over `codex app-server`.

  The counterpart to `ChatTransport.ClaudeDuplex`, and the phase that brings
  Codex to parity: it gains **both** true mid-turn steering and real
  conversation continuity. Under `ChatTransport.Codex` (`codex exec`) a chat had
  neither — every turn was a fresh process with no memory of the last one,
  because `codex exec resume` is a subcommand `AgentBackend.argv/3` cannot
  express.

  ## Shape

  Unlike the two pipe-based transports, this one owns no process of its own. The
  connection is `BusterClaw.Agent.CodexAppServer`, one per application,
  multiplexing every conversation by thread id — a codex app-server boots the
  operator's MCP servers per thread, so a server per tab would multiply that
  cost by the number of tabs.

  The handle therefore carries a `ref` rather than a port. Events arrive at the
  `Chat` process as `{:chat_event, ref, %StreamEvent{}}`, already normalized, and
  a lost connection arrives as `{:chat_transport_down, ref, reason}`.

  ## Receipts

  `:turn_addressed`, the strongest of the three. `turn/steer` carries
  `expectedTurnId` and returns `{turnId}`; a stale id or a finished turn is
  refused outright with `-32600`. **The completion race is guarded by the
  protocol**, so unlike the other backends Buster Claw is not inferring it.

  ## Confinement

  `thread/start` takes the same three-value `SandboxMode` enum that
  `AgentBackend.permission_args/2` already emits as `-s`, so the translation is
  one-to-one. Phase 0 verified `read-only` genuinely refuses a write
  (`operation not permitted`).

  ⚠ It does **not** scope MCP — a codex thread sees whatever servers the
  operator has configured, exactly as `codex exec` does. Not a regression, but
  not a clearance either: the money surfaces stay Claude-pinned.
  """

  @behaviour BusterClaw.Agent.ChatTransport

  require Logger

  alias BusterClaw.Agent.AttentionContract
  alias BusterClaw.Agent.ChatTransport
  alias BusterClaw.Agent.CodexAppServer

  @impl true
  def open(opts), do: {:ok, ChatTransport.build(Keyword.get(opts, :agent, :codex), opts)}

  @impl true
  def capabilities do
    %{
      modes: [:start_turn, :queue_next, :steer, :interrupt],
      receipt: :turn_addressed,
      # The thread outlives every turn, so `Chat` ends turns on `turn/completed`
      # rather than on a process exit — there is no per-turn process here at all.
      persistent: true
    }
  end

  @impl true
  def start_turn(handle, text) do
    with {:ok, handle} <- ensure_thread(handle),
         {:ok, turn_id} <-
           server().start_turn(server(), handle.session_id, text, model: handle.model) do
      {:ok, put_turn(handle, turn_id), turn_id}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def steer(handle, turn_ref, text) do
    cond do
      is_nil(handle.session_id) ->
        {:error, :no_active_turn}

      current_turn(handle) != turn_ref ->
        # Guarded here as well as by the protocol. Asking the server about a turn
        # we already know is stale would be a round trip to be told what we knew.
        {:error, :no_active_turn}

      true ->
        case server().steer(server(), handle.session_id, turn_ref, text) do
          {:ok, turn_id} -> {:ok, handle, %{turn_id: turn_id}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def interrupt(handle, turn_ref) do
    if handle.session_id && turn_ref do
      server().interrupt(server(), handle.session_id, turn_ref)
    end

    {:ok, %{handle | conn: nil}}
  end

  @impl true
  def close(handle) do
    # The THREAD is not deleted — only our interest in it. A closed tab that is
    # reopened resumes where it was, which is the whole point of the thread id
    # being durable.
    if ref(handle), do: server().unregister(server(), ref(handle))
    :ok
  end

  # --- thread lifecycle ----------------------------------------------------

  # Start a thread on first use, resume a known one afterwards. `session_id` is
  # `Chat`'s durable per-conversation identifier, and for this backend it holds
  # the codex thread id — which is exactly what makes a second turn able to refer
  # to the first.
  # ⚠ `conn` is bound ONCE and reused. `conn_map/1` mints a fresh `make_ref()`
  # for a handle that has none, so calling it twice — once to register, once to
  # store — hands the connection one ref and keeps a different one. Every
  # notification then routes to a ref nobody is listening on: the transcript
  # stays empty and the turn sits until its timeout.
  #
  # That shipped, and no unit test caught it, because the fakes have their own
  # correct ref handling and the connection tests supply their own refs. The
  # real adapter's ref plumbing was the one seam nothing crossed. The Codex
  # acceptance smoke found it on its first run.
  defp ensure_thread(%{session_id: nil} = handle) do
    conn = conn_map(handle)

    case server().start_thread(server(), conn.ref, thread_opts(handle)) do
      {:ok, thread_id} ->
        {:ok, attach(handle, conn, thread_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_thread(handle) do
    if registered?(handle) do
      {:ok, handle}
    else
      conn = conn_map(handle)

      case server().resume_thread(
             server(),
             conn.ref,
             handle.session_id,
             thread_opts(handle)
           ) do
        {:ok, _thread_id} -> {:ok, attach(handle, conn, handle.session_id)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The one place the handle learns its routing ref, so registration and
  # matching cannot disagree. `Chat` matches incoming messages against
  # `handle.port` whatever the transport; there is no port here, so the ref
  # takes its place — one matching rule for every backend rather than a special
  # case in `Chat`.
  defp attach(handle, conn, thread_id),
    do: %{
      handle
      | session_id: thread_id,
        conn: Map.put(conn, :registered?, true),
        port: conn.ref
    }

  defp thread_opts(handle) do
    [
      permission_mode: handle.permission_mode,
      model: handle.model,
      cwd: BusterClaw.Library.Artifact.workspace_root(),
      # `developerInstructions`, NOT `baseInstructions`: the latter replaces
      # codex's own system prompt rather than adding to it. This carries the
      # conversation's guide, which this transport was silently dropping until
      # the attention contract needed the same channel.
      instructions: AttentionContract.compose(handle.append_system_prompt, true)
    ]
  end

  # --- handle plumbing -----------------------------------------------------
  #
  # `:conn` holds `%{ref: reference(), turn_ref: term(), registered?: boolean()}`.
  # The ref is what the connection routes events to, and it must survive across
  # turns — a fresh one per turn would orphan the stream mid-conversation.

  defp conn_map(%{conn: %{} = conn}), do: conn
  defp conn_map(_handle), do: %{ref: make_ref(), turn_ref: nil, registered?: false}

  defp ref(%{conn: %{ref: ref}}), do: ref
  defp ref(_handle), do: nil

  defp registered?(%{conn: %{registered?: true}}), do: true
  defp registered?(_handle), do: false

  defp put_turn(handle, turn_id),
    do: %{
      handle
      | conn: Map.put(conn_map(handle), :turn_ref, turn_id) |> Map.put(:registered?, true)
    }

  defp current_turn(%{conn: %{turn_ref: ref}}), do: ref
  defp current_turn(_handle), do: nil

  # Injectable so a test can watch what ref is handed over. Without this seam
  # the adapter's ref plumbing is unreachable from the suite — which is exactly
  # how the double-`make_ref` bug reached a real run.
  defp server, do: Application.get_env(:buster_claw, :codex_app_server, CodexAppServer)
end
