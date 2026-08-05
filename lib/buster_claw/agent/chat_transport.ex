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
  `daily-growth/roadmaps/CHAT_LIVE_STEERING_ROADMAP.md`). They do **not** differ
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
  """

  alias BusterClaw.AgentBackend

  @typedoc """
  Everything an adapter needs to run one conversation's turns.

  Shared across the three Phase 1 adapters because they genuinely differ only in
  argv and prompt placement. Phase 2+ adapters that hold a socket or a server
  connection keep it in `:conn`, which nothing else interprets.

  `:session_id` and `:port` are written by `Chat` as it parses the stream —
  `Chat` is the one that sees the events, so it is the one that learns the
  session id.
  """
  @type t :: %__MODULE__{
          agent: atom(),
          session_id: String.t() | nil,
          append_system_prompt: String.t() | nil,
          extra_cli_args: [String.t()],
          permission_mode: String.t() | nil,
          spawner: (String.t(), keyword() -> {:ok, term()} | {:error, term()}),
          port: term() | nil,
          conn: term() | nil
        }

  defstruct agent: nil,
            session_id: nil,
            append_system_prompt: nil,
            extra_cli_args: [],
            permission_mode: nil,
            spawner: nil,
            port: nil,
            conn: nil

  @typedoc """
  What a backend can do, and what it can prove.

  * `:modes` — `:start_turn`, `:queue_next`, `:steer`, `:interrupt`.
    **`:queue_next` is always present**: it is Buster Claw's own behaviour (hold
    the message, send it as the next turn) and needs nothing from the backend.
  * `:receipt` — `:none`, `:boundary_replay`, `:turn_addressed`, or
    `:admission_event`. `:none` means the UI may say *sent*, never *steered*.
  """
  @type capabilities :: %{
          modes: [:start_turn | :queue_next | :steer | :interrupt],
          receipt: :none | :boundary_replay | :turn_addressed | :admission_event
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
  Spawn a one-shot streaming turn: the shape every adapter used before this
  module existed, and still the shape all three use in Phase 1.

  `argv_extra` is the backend's own flag list; `prompt` is whatever that backend
  wants as its positional prompt.
  """
  @spec spawn_turn(t(), String.t(), [String.t()]) :: {:ok, t(), reference()} | {:error, term()}
  def spawn_turn(handle, prompt, argv_extra) do
    opts =
      [extra_args: argv_extra, login: true, agent: handle.agent]
      |> maybe_put(:permission_mode, handle.permission_mode)

    case handle.spawner.(prompt, opts) do
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
