defmodule BusterClaw.Agent.ChatTransport do
  @moduledoc """
  How a chat conversation talks to one agent harness.

  `BusterClaw.Agent.Chat` owns ordering, persistence, the transcript, audit, and
  every product decision. This behavior owns the part that differs per CLI:
  which argv to build, where the prompt goes, how a turn is started, and — from
  Phase 2 onward — how a message is delivered into a turn that is already
  running.

  ## Why this exists

  `Chat.start_run/2` used to assemble claude's argv inline and then special-case
  the other two harnesses beside it (`resume_args/2`, `append_system_prompt_args/2`,
  `prompt_for/3`). That worked while every backend was "spawn a process with some
  flags", and stops working the moment one of them is a JSON-RPC server and
  another is an HTTP server with an SSE stream. The protocols do not share a
  shape, so the shape belongs behind an adapter.

  ## Phase 1 is deliberately behaviour-preserving

  All three adapters are currently **one-shot**: `start_turn/2` spawns a process
  per turn exactly as before, and `steer/3` answers `{:error, :not_supported}`.
  Nothing an operator can see has changed. The `steer/3` callback exists now so
  Phase 2 fills it in rather than reshaping every call site.

  ## Capabilities, and why a boolean is not enough

  Phase 0 measured all three harnesses steering (see
  `daily-growth/archive/08-06-26-chat-live-steering.md`). They do **not** differ
  on whether steering works. They differ on what they can *prove*, which is what
  the UI is allowed to claim:

  | Backend | Steer mechanism | Receipt available |
  |---|---|---|
  | claude | JSONL on an open stdin | `:boundary_replay` — `--replay-user-messages`, echoed when the in-flight tool ends |
  | codex | `turn/steer` with `expectedTurnId` | `:turn_addressed` — a `{turnId}` response, and a hard error on a stale id |
  | opencode | v1 `prompt_async` on a busy session | `:admission_event` — the HTTP body is EMPTY; acceptance comes from an SSE `message.updated` ~20ms later |

  So `capabilities/0` reports a receipt kind alongside the modes. A backend that
  cannot produce a receipt must not render "STEERED".

  ## The latency law

  Measured on all three, on three unrelated protocols: a steered message is acted
  on at the **next tool boundary**, and the in-flight tool sets the wait. There is
  no mechanism anywhere here for reaching a model mid-inference, and adapters must
  not imply one.

  ## Attachments are applied HERE, and that is deliberate

  `Chat` decides *which* files ride with a turn; this layer decides *how* they
  reach the CLI, because this is the layer that knows how the CLI is invoked at
  all. `Chat` no longer builds an argv, and `AgentRunner` has no idea what an
  attachment is — it takes `:extra_args` and a prompt, which is all a delivery
  ever becomes.

  There are three places a turn actually leaves the BEAM, and each takes its own
  route through `BusterClaw.Agent.AttachmentDelivery`:

  | Route | Applied in | What it can carry |
  |---|---|---|
  | one-shot spawn (`claude -p`, `codex exec`, `opencode run`) | `spawn_turn/3` below | `{:args, …}` and `{:prompt_prefix, …}` |
  | duplex pipe (`ChatTransport.ClaudeDuplex`) | that adapter's `write/3` | `{:inline, …}` blocks and `{:prompt_prefix, …}` |
  | a server connection (`CodexAppServer`, `OpenCodeServer`) | `path_only_deliveries/1` | `{:prompt_prefix, …}` only |

  Applying this one layer up — in `Chat` — would have covered exactly one of
  those and silently no-op'd the rest, which is the bug this wiring exists to
  fix, reproduced one layer down.

  **With no attachments every route is byte-identical to what shipped before they
  existed**: `AttachmentDelivery.deliveries/3` answers `[]` for an empty list, so
  the argv gains `++ []`, the prompt gains nothing, and the JSONL line keeps its
  bare-string `content`.
  """

  alias BusterClaw.Agent.Attachment
  alias BusterClaw.Agent.AttachmentDelivery
  alias BusterClaw.AgentBackend

  @typedoc """
  Everything an adapter needs to run one conversation's turns.

  Shared across the three Phase 1 adapters because they genuinely differ only in
  argv and prompt placement. Phase 2+ adapters that hold a socket or a server
  connection keep it in `:conn`, which nothing else interprets.

  `:session_id` and `:port` are written by `Chat` as it parses the stream —
  `Chat` is the one that sees the events, so it is the one that learns the
  session id.

  `:attachments` is the one field that belongs to a **turn** rather than to the
  conversation. `Chat` writes it immediately before every `start_turn/2` and
  `steer/3` and clears it immediately after, so a file dropped for one message
  cannot ride along with the next — see `put_attachments/2`.
  """
  @type t :: %__MODULE__{
          agent: atom(),
          session_id: String.t() | nil,
          append_system_prompt: String.t() | nil,
          extra_cli_args: [String.t()],
          permission_mode: String.t() | nil,
          model: String.t() | nil,
          spawner: (String.t(), keyword() -> {:ok, term()} | {:error, term()}),
          port: term() | nil,
          conn: term() | nil,
          attachments: [Attachment.t()]
        }

  defstruct agent: nil,
            session_id: nil,
            append_system_prompt: nil,
            extra_cli_args: [],
            permission_mode: nil,
            model: nil,
            spawner: nil,
            port: nil,
            conn: nil,
            attachments: []

  @typedoc """
  What a backend can do, and what it can prove.

  * `:modes` — `:start_turn`, `:queue_next`, `:steer`, `:interrupt`.
    **`:queue_next` is always present**: it is Buster Claw's own behaviour (hold
    the message, send it as the next turn) and needs nothing from the backend.
  * `:receipt` — `:none`, `:boundary_replay`, `:turn_addressed`, or
    `:admission_event`. `:none` means the UI may say *sent*, never *steered*.
  * `:persistent` — the transport outlives a turn. This changes what `Chat` may
    conclude from the two things it observes: with a persistent transport a
    `result` event ends the TURN and an OS exit is a transport FAILURE, whereas
    a one-shot transport ends its turn by exiting. Getting this backwards either
    hangs the conversation on a turn that finished or reports a crash as a
    clean completion.
  """
  @type capabilities :: %{
          modes: [:start_turn | :queue_next | :steer | :interrupt],
          receipt: :none | :boundary_replay | :turn_addressed | :admission_event,
          persistent: boolean()
        }

  @type turn_ref :: term()
  @type receipt :: map()

  @doc "Build a handle for a conversation. Pure — it starts nothing."
  @callback open(keyword()) :: {:ok, t()} | {:error, term()}

  @doc "What this backend can do and prove, as currently implemented."
  @callback capabilities() :: capabilities()

  @doc """
  Begin a new turn carrying `text`. Returns the handle with any transport state
  attached, plus a reference identifying the turn for `steer/3` and `interrupt/2`.
  """
  @callback start_turn(t(), String.t()) :: {:ok, t(), turn_ref()} | {:error, term()}

  @doc """
  Deliver `text` into the turn `turn_ref` identifies, which is expected to still
  be running.

  `{:error, :no_active_turn}` is the **race** outcome and is not a failure:
  `Chat` demotes the message to the front of the next-turn queue. Phase 1 answers
  `{:error, :not_supported}` everywhere.
  """
  @callback steer(t(), turn_ref(), String.t()) ::
              {:ok, t(), receipt()} | {:error, :not_supported | :no_active_turn | term()}

  @doc "Stop the identified turn. Already-completed external effects are not undone."
  @callback interrupt(t(), turn_ref()) :: {:ok, t()} | {:error, term()}

  @doc "Release everything this handle owns."
  @callback close(t()) :: :ok

  # NOTE: there is deliberately no `for_agent/1` here. An adapter must depend on
  # this module for `@behaviour`, so naming the adapters back from here would
  # make the four files a dependency cycle — which `scripts/check_cycles.sh`
  # catches, correctly. The harness → adapter mapping lives in
  # `BusterClaw.Agent.Chat`, its only caller.

  @doc """
  Build a handle from `Chat`'s per-conversation options. Shared by all three
  Phase 1 adapters, which differ only in how they spend it.
  """
  @spec build(atom(), keyword()) :: t()
  def build(agent, opts) do
    %__MODULE__{
      agent: agent,
      session_id: Keyword.get(opts, :session_id),
      append_system_prompt: Keyword.get(opts, :append_system_prompt),
      extra_cli_args: Keyword.get(opts, :extra_cli_args, []),
      permission_mode: Keyword.get(opts, :permission_mode),
      # Only the server-backed transports read this. The pipe transports get
      # their model from `Chat`'s spawner, which resolves it at the last moment
      # before the spawn; a transport with no spawn has nowhere else to put it.
      model: Keyword.get(opts, :model),
      spawner: Keyword.get(opts, :spawner)
    }
  end

  @doc """
  Record the session/thread id `Chat` parsed out of the stream.

  Tolerates a nil handle: `Chat` can see a session id from a stale run's port
  after the handle has been cleared, and that must not crash the conversation.
  """
  @spec put_session(t() | nil, String.t() | nil) :: t() | nil
  def put_session(nil, _id), do: nil
  def put_session(handle, id) when is_binary(id), do: %{handle | session_id: id}
  def put_session(handle, _id), do: handle

  @doc """
  Hang `attachments` on the handle for the NEXT call only.

  It is scratch space, not conversation state. `Chat` sets it before each
  `start_turn/2` or `steer/3` and puts `[]` back on the handle it stores, because
  a persistent transport's handle outlives its turn and a screenshot dropped into
  one message must not be re-delivered with every message after it.

  Tolerates a nil handle for the same reason `put_session/2` does.
  """
  @spec put_attachments(t() | nil, [Attachment.t()]) :: t() | nil
  def put_attachments(nil, _attachments), do: nil

  def put_attachments(handle, attachments) when is_list(attachments),
    do: %{handle | attachments: attachments}

  @doc """
  The deliveries this handle's attachments need, on this handle's backend.

  `:duplex` is passed through to `AttachmentDelivery.deliveries/3` — `true` only
  on claude's streaming-input path, which is the one route that can carry bytes.
  """
  @spec deliveries(t(), keyword()) :: [Attachment.delivery()]
  def deliveries(handle, opts \\ []),
    do: AttachmentDelivery.deliveries(handle.agent, handle.attachments, opts)

  @doc """
  Deliveries for a transport that has **no argv and no inline channel** — the two
  server-backed adapters, which reach their backend over JSON-RPC or HTTP.

  The backend is deliberately asked for as `nil`. That is not a backend name and
  is not meant to be one: `AttachmentDelivery` has no flag and no directory grant
  for an unrecognised backend, so every attachment resolves to the one mechanism
  a server connection can actually deliver — text inlined into the prompt, and
  everything else named there by absolute path. Asking as `:codex` here would
  produce `-i` flags with nowhere to put them, which is a silent drop.
  """
  @spec path_only_deliveries(t()) :: [Attachment.delivery()]
  def path_only_deliveries(handle), do: AttachmentDelivery.deliveries(nil, handle.attachments)

  @doc """
  `prompt` with any attachment prefix in front of it.

  Returns `prompt` **unchanged** when there is no prefix, which is what keeps an
  ordinary turn byte-identical.
  """
  @spec prefixed(String.t(), [Attachment.delivery()]) :: String.t()
  def prefixed(prompt, deliveries) do
    case AttachmentDelivery.prompt_prefix(deliveries) do
      "" -> prompt
      prefix -> prefix <> "\n\n" <> prompt
    end
  end

  @doc """
  Spawn a one-shot streaming turn: the shape every adapter used before this
  module existed, and still the shape the three pipe adapters use.

  `argv_extra` is the backend's own flag list; `prompt` is whatever that backend
  wants as its positional prompt. Attachment flags are appended AFTER the
  backend's own — `--add-dir`, `-i` and `-f` are all order-independent, and
  keeping them last means the argv a reader already knows stays where it was.
  """
  @spec spawn_turn(t(), String.t(), [String.t()]) :: {:ok, t(), reference()} | {:error, term()}
  def spawn_turn(handle, prompt, argv_extra) do
    # `deliveries/2` with no `:duplex`, because this function IS the non-duplex
    # path: a positional prompt and a process that ends with its turn. There is
    # no channel here for an inline block, and `AttachmentDelivery` knows it.
    deliveries = deliveries(handle)

    opts =
      [
        extra_args: argv_extra ++ AttachmentDelivery.args(deliveries),
        login: true,
        agent: handle.agent
      ]
      |> maybe_put(:permission_mode, handle.permission_mode)

    case handle.spawner.(prefixed(prompt, deliveries), opts) do
      {:ok, port} ->
        # The port doubles as the turn ref while turns are one-shot: there is
        # exactly one turn per process, so they identify the same thing. Phase 2
        # separates them, because a long-lived process has many turns.
        {:ok, %{handle | port: port}, port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The structured-output flags for this handle's backend."
  @spec stream_args(t()) :: [String.t()]
  def stream_args(handle), do: AgentBackend.stream_args(handle.agent, stream: true)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
