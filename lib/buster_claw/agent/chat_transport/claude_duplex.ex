defmodule BusterClaw.Agent.ChatTransport.ClaudeDuplex do
  @moduledoc """
  Claude Code as a **long-lived duplex conversation** — the transport that makes
  live steering real.

  One `claude` process per conversation, started with `--input-format stream-json`
  as well as `--output-format stream-json`, and kept alive across turns with
  stdin open. Operator messages are JSONL lines written with `Port.command/2`.
  The first one starts the work; a later one written while tools or model turns
  are active is taken into that same turn.

  Measured on claude 2.1.222 by `scripts/probe_claude_duplex.exs`. What the probe
  established, and what this module is built around:

  * **Steering works, at the next tool boundary.** Injecting during model text
    and during a tool call produced the same result, because in both cases the
    message was acted on once the in-flight tool returned (~8s, the length of the
    tool). Injecting *before* a tool call did not stop that call from starting —
    the model had already committed to it. Nothing here reaches a model
    mid-inference, and nothing here should imply it does.
  * **`result` ends a TURN, not the transport.** The process survived and
    answered a second message on the same stdin and session.
  * **`system/init` re-emits at the start of every turn**, same session id, same
    capability list — so capabilities can be read per turn, and nothing may latch
    on "the first init".
  * **The receipt is the replayed user message.** See
    `BusterClaw.Agent.ChatMessageEncoder` for the string-vs-blocks discriminator.

  ## Why this is a separate module from `ChatTransport.Claude`

  It is a different **lifecycle**, not one more flag: stdin stays open, the turn
  boundary moves from process exit to an event, and the process outlives the
  turn. Keeping the one-shot adapter intact means the shipped path is reachable
  by flipping `:chat_live_steering_enabled` back off, with no code removed.

  ## Interrupt

  Phase 2 interrupts by killing the process group and letting the next turn
  resume the saved session — the roadmap's stated fallback for "the transport
  cannot confirm interruption". Claude advertises `interrupt_receipt_v1` and
  `interrupt_cancel_queued_v1` on init, so a later pass can interrupt the turn
  while keeping the process; that is a protocol this module does not yet speak,
  and pretending otherwise would leave a turn running that we reported as
  stopped.
  """

  @behaviour BusterClaw.Agent.ChatTransport

  require Logger

  alias BusterClaw.Agent.ChatMessageEncoder
  alias BusterClaw.Agent.ChatTransport

  @impl true
  def open(opts), do: {:ok, ChatTransport.build(Keyword.get(opts, :agent), opts)}

  @impl true
  def capabilities do
    %{
      modes: [:start_turn, :queue_next, :steer, :interrupt],
      receipt: :boundary_replay,
      # The process outlives the turn, so `Chat` must end turns on the `result`
      # event and read an OS exit as transport failure rather than completion.
      persistent: true
    }
  end

  @impl true
  def start_turn(handle, text) do
    with {:ok, handle} <- ensure_process(handle),
         {:ok, handle, _receipt} <- write(handle, text) do
      # A fresh reference per turn. It cannot be the port any more — one process
      # now has many turns — and it is what makes a steer addressable to the turn
      # the operator was actually looking at.
      turn_ref = make_ref()
      {:ok, put_turn(handle, turn_ref), turn_ref}
    end
  end

  @impl true
  def steer(handle, turn_ref, text) do
    cond do
      not alive?(handle) ->
        {:error, :no_active_turn}

      current_turn(handle) != turn_ref ->
        # The turn the operator aimed at is over. Never apply this to whatever
        # turn happens to be current — `Chat` demotes it to the front of the
        # queue instead.
        {:error, :no_active_turn}

      true ->
        write(handle, text)
    end
  end

  @impl true
  def interrupt(handle, _turn_ref) do
    if is_port(handle.port), do: BusterClaw.AgentRunner.kill_port(handle.port)
    # Session id is deliberately kept: the next turn resumes the conversation in
    # a fresh process rather than losing its context to a stop.
    {:ok, %{handle | port: nil, conn: nil}}
  end

  @impl true
  def close(handle) do
    if is_port(handle.port), do: BusterClaw.AgentRunner.kill_port(handle.port)
    :ok
  end

  # --- process lifecycle ---------------------------------------------------

  # Lazily start the conversation's process, and restart it after a crash. The
  # saved session id is replayed as `--resume`, so a transport failure costs the
  # in-flight turn but not the conversation.
  defp ensure_process(handle) do
    if alive?(handle) do
      {:ok, handle}
    else
      spawn_opts =
        [
          duplex: true,
          stream: true,
          login: true,
          agent: handle.agent,
          extra_args: extra_args(handle)
        ]
        |> maybe_put(:permission_mode, handle.permission_mode)

      # No positional prompt: in streaming-input mode the first message arrives
      # on stdin like every later one, which is exactly what keeps the two paths
      # identical.
      case handle.spawner.("", spawn_opts) do
        {:ok, port} -> {:ok, %{handle | port: port, conn: nil}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp extra_args(handle) do
    resume_args(handle.session_id) ++
      append_args(handle.append_system_prompt) ++ handle.extra_cli_args
  end

  defp resume_args(nil), do: []
  defp resume_args(session_id), do: ["--resume", session_id]

  defp append_args(nil), do: []
  defp append_args(""), do: []
  defp append_args(prompt), do: ["--append-system-prompt", prompt]

  # A port whose process has gone leaves the port itself looking fine to
  # `is_port/1`; `Port.info/1` returning nil is what actually says it is dead.
  defp alive?(%{port: port}) when is_port(port), do: Port.info(port) != nil
  defp alive?(_handle), do: false

  # --- writing -------------------------------------------------------------

  defp write(handle, text) do
    case ChatMessageEncoder.encode_user(text) do
      {:ok, line} ->
        Port.command(handle.port, line)
        {:ok, handle, %{written_bytes: byte_size(line)}}

      {:error, {:too_large, size, limit}} = error ->
        # Refused BEFORE the pipe write. A half-written line would desynchronise
        # claude's parser for the rest of the conversation, which is much worse
        # than a rejected message.
        Logger.warning("Chat: refused a #{size}-byte message (limit #{limit})")
        error
    end
  rescue
    # The process died between the liveness check and the write.
    ArgumentError -> {:error, :no_active_turn}
  end

  defp put_turn(handle, turn_ref), do: %{handle | conn: %{turn_ref: turn_ref}}
  defp current_turn(%{conn: %{turn_ref: ref}}), do: ref
  defp current_turn(_handle), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
