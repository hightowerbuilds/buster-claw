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
  * **The receipt is the replayed user message** — see
    `BusterClaw.Agent.ChatMessageEncoder` for the string-vs-blocks
    discriminator. **Nothing consumes that replay yet**, so `steer/3` reports
    `:unconfirmed` rather than letting a bare pipe write masquerade as proof;
    the UI says "sent", the ledger says "uncertain", and both are the truth.

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

  ## Attachments: the one route where no file need exist

  This is the only transport that can put attachment **bytes** on the wire, and
  it is why `AgentBackend.inline_attachments?/2` is keyed on `:duplex`. An image
  becomes a base64 block in the message's `content` array (see
  `BusterClaw.Agent.ChatMessageEncoder`), a text file becomes a text block, and
  claude answers with no file on disk and no Read tool call. A steered message
  carries them the same way, because it is the same write.

  ⚠ **A directory grant can only be made when the process is spawned.** The
  `{:args, ["--add-dir", …]}` delivery — which only a PDF or another binary
  produces here, since images and text inline — is applied in `ensure_process/2`,
  so it lands on the first turn of a conversation and on any turn that respawns
  after a crash. On turn five of a live process there is no way to add a flag to
  an argv fixed four turns ago; the file is still named by absolute path in the
  prompt prefix, and chat's default `bypassPermissions` is what lets claude read
  it. Restarting the process to widen the grant would cost the operator the live
  conversation, which is a far worse trade than an unflagged path.
  """

  @behaviour BusterClaw.Agent.ChatTransport

  require Logger

  alias BusterClaw.Agent.AttachmentDelivery
  alias BusterClaw.Agent.AttentionContract
  alias BusterClaw.Agent.ChatMessageEncoder
  alias BusterClaw.Agent.ChatTransport

  @impl true
  def open(opts), do: {:ok, ChatTransport.build(Keyword.get(opts, :agent), opts)}

  @impl true
  def capabilities do
    %{
      modes: [:start_turn, :queue_next, :steer, :interrupt],
      # The KIND of receipt this wire offers. Offers, not yet delivers: until
      # the replay echo is consumed, every steer's per-call receipt is
      # `:unconfirmed` (see `steer/3`), and that per-call value — not this
      # field — is what decides whether "STEERED" may render.
      receipt: :boundary_replay,
      # The process outlives the turn, so `Chat` must end turns on the `result`
      # event and read an OS exit as transport failure rather than completion.
      persistent: true
    }
  end

  @impl true
  def start_turn(handle, text) do
    # Computed once and spent twice: the args half can only be applied if this
    # turn is the one that spawns the process, and the inline half rides the
    # message either way.
    deliveries = ChatTransport.deliveries(handle, duplex: true)

    with {:ok, handle} <- ensure_process(handle, deliveries),
         {:ok, handle, _receipt} <- write(handle, text, deliveries) do
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
        # A steered message may carry its own attachments — same channel, same
        # encoder. Only the inline blocks and the prompt prefix can apply: the
        # process is by definition already running.
        #
        # `:unconfirmed`, because a successful `Port.command/2` proves only that
        # WE wrote — the wire's actual proof is the `--replay-user-messages`
        # echo at the next boundary, and nothing consumes that echo yet
        # (`ChatMessageEncoder.operator_replay?/1` is the ready-made
        # discriminator, currently unused). Claiming `:steered` on a bare write
        # is exactly the false claim the ChatTransport contract forbids; `Chat`
        # maps `:unconfirmed` to `:sent`/"uncertain", the same honest downgrade
        # OpenCode's receiptless v1 path takes. Upgrading this to a real
        # `:steered` means consuming the replay — filed in
        # LEFTOVERS_AGENT_CORE, not faked here.
        with {:ok, handle, receipt} <-
               write(handle, text, ChatTransport.deliveries(handle, duplex: true)) do
          {:ok, handle, Map.put(receipt, :receipt, :unconfirmed)}
        end
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
  defp ensure_process(handle, deliveries) do
    if alive?(handle) do
      {:ok, handle}
    else
      spawn_opts =
        [
          duplex: true,
          stream: true,
          login: true,
          agent: handle.agent,
          # `[]` unless a binary attachment needs a directory grant, so an
          # ordinary turn's argv is unchanged. See the moduledoc on why a grant
          # is only ever available at spawn time.
          extra_args: extra_args(handle) ++ AttachmentDelivery.args(deliveries)
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
    # The conversation's guide AND the attention contract — this transport can
    # steer, so the contract describes something that genuinely happens here.
    instructions = AttentionContract.compose(handle.append_system_prompt, true)

    resume_args(handle.session_id) ++ append_args(instructions) ++ handle.extra_cli_args
  end

  defp resume_args(nil), do: []
  defp resume_args(session_id), do: ["--resume", session_id]

  # Always a string here: a steerable transport always has at least the
  # attention contract to say, so `AttentionContract.compose/2` never returns
  # nil on this path.
  defp append_args(prompt) when is_binary(prompt), do: ["--append-system-prompt", prompt]

  # A port whose process has gone leaves the port itself looking fine to
  # `is_port/1`; `Port.info/1` returning nil is what actually says it is dead.
  defp alive?(%{port: port}) when is_port(port), do: Port.info(port) != nil
  defp alive?(_handle), do: false

  # --- writing -------------------------------------------------------------

  defp write(handle, text, deliveries) do
    # With no attachments this is `encode_user(text, [])`, which is the bare
    # string `content` that has shipped since duplex landed — the encoder's own
    # tests pin that shape.
    case ChatMessageEncoder.encode_user(
           ChatTransport.prefixed(text, deliveries),
           AttachmentDelivery.blocks(deliveries)
         ) do
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
