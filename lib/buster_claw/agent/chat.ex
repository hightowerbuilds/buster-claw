defmodule BusterClaw.Agent.Chat do
  @moduledoc """
  A real-time chat conversation backed by **headless Claude**.

  Each user message spawns a short-lived `claude -p` run with
  `--output-format stream-json`, owned by this GenServer (inside the BEAM, so it
  can broadcast — the `./buster-claw` escript cannot). As the run streams NDJSON
  events, they are parsed by `BusterClaw.Agent.StreamEvent` and broadcast on the
  conversation's PubSub topic; the homepage chat LiveView renders from those.

  ## Conversation model

  One short-lived run per message, threaded with `--resume`. The first message
  runs with no session flag; we capture the `session_id` from the stream and pass
  `--resume <id>` on every subsequent message, so the agent keeps context without
  a long-lived process. State survives the run process exiting between turns.

  ## Discipline (borrowed from `BusterClaw.Dispatcher`)

  - **Serialized.** One run in flight per conversation; `send_message/2` returns
    `{:error, :busy}` while a run is active.
  - **Wall-clock cap.** A hung run is killed and reported as `{:error, :timeout}`.
  - **Crash-safe.** The run is a monitored Port; if it dies the conversation
    resets to idle.

  ## Trust boundary

  Unchanged from the rest of the app: the agent drives `./buster-claw`, and
  `BusterClaw.Commands` (tier + provenance gate) is the real authorization
  boundary. **Chat input is untrusted user text.**
  """
  use GenServer

  require Logger

  alias BusterClaw.Agent.ChatTransport
  alias BusterClaw.Agent.StreamEvent
  alias BusterClaw.Agent.Transcript
  alias BusterClaw.AgentRunner
  alias BusterClaw.ModelPolicy
  alias BusterClaw.Sentinel
  alias Phoenix.PubSub

  @default_conv_id "default"
  @default_timeout_ms 10 * 60 * 1000
  @registry BusterClaw.Agent.ChatRegistry
  @supervisor BusterClaw.Agent.ChatSupervisor

  # --- Public API ---

  @doc """
  Start a conversation's chat process. `conv_id` is required and the process
  registers under it in `ChatRegistry`, so each conversation is its own process.
  """
  def start_link(opts) do
    conv_id = Keyword.get(opts, :conv_id, @default_conv_id)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :conv_id, conv_id), name: via(conv_id))
  end

  @doc "The default (seeded) conversation id."
  def default_conv_id, do: @default_conv_id

  @doc "The PubSub topic a conversation's events are broadcast on."
  def topic(conv_id \\ @default_conv_id), do: "agent_chat:#{conv_id}"

  @doc "Subscribe the calling process to a conversation's events."
  def subscribe(conv_id \\ @default_conv_id),
    do: PubSub.subscribe(BusterClaw.PubSub, topic(conv_id))

  @doc """
  Send a user message to a conversation, starting its process on demand. Spawns a
  headless run unless one is already in flight. Returns `:ok`, `{:error, :busy}`,
  or `{:error, reason}`.
  """
  def send_message(conv_id, text) when is_binary(conv_id) and is_binary(text) do
    # Flattens `submit/3`'s effective mode back to a bare `:ok`. Kept because
    # every existing call site and test was written against this contract, and
    # Phase 1 is an extraction, not a behaviour change. New call sites should
    # use `submit/3` and render the mode it returns.
    case submit(conv_id, text, delivery: :auto) do
      {:ok, _mode} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Submit a user message with an explicit delivery mode.

  * `:auto` — today's behaviour, and what `send_message/2` asks for: start a turn
    when idle, queue it when a run is in flight.
  * `:next` — queue as its own follow-up turn, never touching the active one.
    Deliberate even when the chat is idle, where it is the same as starting a turn.
  * `:steer` — deliver into the ACTIVE turn.

  Returns `{:ok, effective_mode}` where `effective_mode` is one of `:started`,
  `:queued`, or `:steered` — the mode that actually happened, which is not always
  the one asked for. `:steer` on an idle chat starts a turn; `:steer` on a backend
  that cannot do it (all of them, until Phase 2) queues instead. **The caller must
  render the returned mode, never the requested one** — showing "steered" for a
  message that was queued is the single most damaging bug this feature can have.
  """
  @spec submit(String.t(), String.t(), keyword()) ::
          {:ok, :started | :queued | :steered} | {:error, term()}
  def submit(conv_id, text, opts \\ []) when is_binary(conv_id) and is_binary(text) do
    delivery = Keyword.get(opts, :delivery, :auto)

    with {:ok, _pid} <- ensure_started(conv_id) do
      GenServer.call(via(conv_id), {:submit, text, delivery})
    end
  end

  @doc """
  What the conversation's backend can do and prove right now — see
  `BusterClaw.Agent.ChatTransport` for the shape.

  Read from the backend the NEXT turn would use, so a UI can label its send
  button before anything is running.
  """
  def capabilities(conv_id) do
    case whereis(conv_id) do
      nil -> ChatTransport.Claude.capabilities()
      pid -> GenServer.call(pid, :capabilities)
    end
  end

  @doc "Current run status of a conversation: `:idle`, `:running`, or `:idle` if no process."
  def status(conv_id) do
    case whereis(conv_id) do
      nil -> :idle
      pid -> GenServer.call(pid, :status)
    end
  end

  @doc "Whether a conversation currently has a run in flight."
  def running?(conv_id), do: status(conv_id) == :running

  @doc "The conversation's pending message queue (`[]` if no process or none queued)."
  def queue(conv_id) do
    case whereis(conv_id) do
      nil -> []
      pid -> GenServer.call(pid, :queue)
    end
  end

  @doc "Drop a not-yet-dispatched message from the queue by its id."
  def remove_queued(conv_id, id) do
    case whereis(conv_id) do
      nil -> :ok
      pid -> GenServer.call(pid, {:remove_queued, id})
    end
  end

  @doc """
  Reorder the queue to match `ids` (a list of queue-item ids, front-first). Ids not
  present are ignored; queued items missing from `ids` keep their relative order at
  the back. A no-op if the conversation has no process.
  """
  def reorder_queue(conv_id, ids) when is_list(ids) do
    case whereis(conv_id) do
      nil -> :ok
      pid -> GenServer.call(pid, {:reorder_queue, ids})
    end
  end

  @doc """
  Interrupt the in-flight run: kill it, mark the turn interrupted, and hand off to
  the queue (the next queued message runs, or the chat settles idle). A no-op if the
  conversation is idle. The killed turn's partial work is lost — `--resume` reverts
  to the last completed turn.
  """
  def interrupt(conv_id) do
    case whereis(conv_id) do
      nil -> :ok
      pid -> GenServer.call(pid, :interrupt)
    end
  end

  @doc """
  Clear a conversation's live state: kill any in-flight run, drop the queue, and
  forget the session id so the next message starts a fresh Claude thread (no
  `--resume`). Broadcasts `{:reset}` so subscribers can clear their view. Does
  **not** touch the persisted transcript — that's the caller's concern
  (`BusterClaw.Agent.Transcript.clear/1`). A no-op if the conversation has no
  process.
  """
  def reset(conv_id) do
    case whereis(conv_id) do
      nil -> :ok
      pid -> GenServer.call(pid, :reset)
    end
  end

  @doc """
  Hard-drop a queued message: move it to the front and, if a run is in flight, cut
  that run so the barged message runs next (Tetris hard-drop). A no-op if `id` isn't
  queued.
  """
  def barge(conv_id, id) do
    case whereis(conv_id) do
      nil -> :ok
      pid -> GenServer.call(pid, {:barge, id})
    end
  end

  @doc """
  Ensure a conversation's chat process is running (started lazily under the
  DynamicSupervisor), returning `{:ok, pid}`. Idempotent and race-safe.

  `start_opts` (`:append_system_prompt`, `:extra_cli_args`, …) are captured
  only when the process actually starts — a no-op once it exists. Changing a
  conversation's profile requires `stop/1` first.
  """
  def ensure_started(conv_id, start_opts \\ []) when is_binary(conv_id) do
    case whereis(conv_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        try do
          child = {__MODULE__, Keyword.put(start_opts, :conv_id, conv_id)}

          case DynamicSupervisor.start_child(@supervisor, child) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
            other -> other
          end
        catch
          # The supervisor isn't running (e.g. the server started before this code
          # was added — a restart is needed). Degrade instead of crashing.
          :exit, _ -> {:error, :chat_unavailable}
        end
    end
  end

  @doc "Stop a conversation's chat process (e.g. when its tab is closed)."
  def stop(conv_id) do
    case whereis(conv_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  defp via(conv_id), do: {:via, Registry, {@registry, conv_id}}

  # Returns the conversation's pid, or nil if it isn't running — including when the
  # ChatRegistry itself isn't started yet (pre-restart live-reload window), so reads
  # like `status/1` degrade to `:idle` rather than raising.
  defp whereis(conv_id) do
    case Registry.lookup(@registry, conv_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    conv_id = Keyword.get(opts, :conv_id, @default_conv_id)

    state = %{
      conv_id: conv_id,
      topic: topic(conv_id),
      session_id: nil,
      status: :idle,
      port: nil,
      buf: "",
      # Bounded tail of NON-stream-json lines from the current run. Claude's
      # real-world failures (not logged in, quota, bad config) print as plain
      # text, which the NDJSON parser used to drop silently — this is what lets
      # a non-zero exit show the user what the CLI actually said.
      raw_tail: [],
      # Messages typed while a run is in flight, dispatched one-per-turn in order.
      queue: [],
      timer: nil,
      timeout_ms:
        Keyword.get(opts, :timeout_ms, configured(:agent_chat_timeout_ms, @default_timeout_ms)),
      persist?: Keyword.get(opts, :persist, configured(:agent_chat_persist, true)),
      audit?: Keyword.get(opts, :audit, configured(:agent_chat_audit, true)),
      # Tracks the in-flight run for the Sentinel audit event on completion.
      run: nil,
      # Optional per-conversation system-prompt addendum (e.g. the homepage chat
      # teaches the SVG-viewer ```svg vocabulary). Passed to `claude` as
      # `--append-system-prompt` on every turn; nil = unchanged behaviour.
      append_system_prompt: Keyword.get(opts, :append_system_prompt),
      # Optional extra CLI flags appended verbatim to every turn's argv (e.g.
      # the trading conversation's `--strict-mcp-config --mcp-config <path>`).
      # Captured at first start like every other opt; [] = unchanged behaviour.
      extra_cli_args: Keyword.get(opts, :extra_cli_args, []),
      # Most conversations inherit AgentRunner's bypassPermissions default.
      # Tool surfaces outside BusterClaw.Commands can choose a deny-by-default
      # Claude mode such as `dontAsk` and pair it with an explicit allowlist.
      permission_mode: Keyword.get(opts, :permission_mode),
      # Which harness this conversation runs in. Resolved by the CALLER (a
      # LiveView, which has DB access) rather than read here: `Chat` must stay
      # usable from `chat_test.exs`, which is async with no sandbox, and a
      # `Settings` read anywhere in the spawn path would raise there. Captured at
      # first start like every other opt, so changing the harness mid-conversation
      # needs a restart — the same contract `append_system_prompt` already has.
      # nil = whatever `AgentRunner.detect/0` finds, which is the shipped state.
      agent: Keyword.get(opts, :agent),
      # Tool names whose USE is consequential enough to land on the audit feed
      # by itself, without waiting for the run to end. Generic on purpose: this
      # module does not learn what a broker is, it learns that some verbs are
      # worth recording the moment they are exercised. Trading supplies the list
      # because its chat holds a cancel verb that reaches a real account with no
      # confirmation card in front of it.
      audit_tools: Keyword.get(opts, :audit_tools, []),
      # The backend adapter driving the CURRENT run, and its handle. Both are nil
      # while idle: the transport is chosen per run from `effective_agent/1`, for
      # the same reason the model is (a run must never inherit a choice made at
      # process start). Phase 2's long-lived Claude conversation is what turns
      # these into state that outlives a turn.
      transport: nil,
      handle: nil,
      # Injectable for tests, like `:spawner` beside it. `steer/3` has no live
      # implementation until Phase 2, so a fake adapter is the only way to cover
      # the accepted-steer and completion-race branches before then — and those
      # are precisely the branches where a bug shows the operator "STEERED" for a
      # message that was actually queued.
      transport_mod: Keyword.get(opts, :transport_mod),
      # Injectable for tests: `spawner.(prompt, opts) :: {:ok, port} | {:error, reason}`.
      spawner: Keyword.get(opts, :spawner, &default_spawner/2)
    }

    {:ok, state}
  end

  # A run is already in flight: queue the message instead of rejecting it. It is
  # dispatched as its own turn when the current run finishes (see dispatch_next/1).
  # The queue is in-memory only — items not yet sent are dropped on restart.
  @impl true
  def handle_call({:submit, text, :steer}, _from, %{status: :running} = state),
    do: steer_or_queue(state, text)

  # `:auto` and `:next` are the same thing while a run is in flight — the
  # message becomes its own turn once this one finishes. They differ only in
  # intent, which matters to the UI, not here.
  def handle_call({:submit, text, _delivery}, _from, %{status: :running} = state),
    do: {:reply, {:ok, :queued}, enqueue(state, text)}

  # Idle: every delivery mode starts a turn. There is no active turn to steer
  # into and nothing to queue behind, so honouring the literal request would
  # just make the operator wait for nothing.
  def handle_call({:submit, text, _delivery}, _from, state) do
    case start_run(state, text) do
      {:ok, state} -> {:reply, {:ok, :started}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:capabilities, _from, state) do
    mod = state.transport_mod || transport_for(effective_agent(state))
    {:reply, mod.capabilities(), state}
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:queue, _from, state), do: {:reply, state.queue, state}

  def handle_call({:remove_queued, id}, _from, state) do
    state = %{state | queue: Enum.reject(state.queue, &(&1.id == id))}
    broadcast_queue(state)
    {:reply, :ok, state}
  end

  def handle_call({:reorder_queue, ids}, _from, state) do
    # Stable sort by the requested position; unlisted items fall to the back in
    # their existing order (Enum.sort_by/2 is stable).
    rank = ids |> Enum.with_index() |> Map.new()
    queue = Enum.sort_by(state.queue, &Map.get(rank, &1.id, length(ids)))
    state = %{state | queue: queue}
    broadcast_queue(state)
    {:reply, :ok, state}
  end

  def handle_call(:interrupt, _from, %{status: :running} = state),
    do: {:reply, :ok, interrupt_running(state)}

  def handle_call(:interrupt, _from, state), do: {:reply, :ok, state}

  # Wipe live state to a clean idle conversation. The killed port's later
  # exit/data messages carry the old (now-nil) port, so handle_info ignores them
  # — same trick as interrupt/1. No transcript churn: unlike interrupt we don't
  # emit an "interrupted" message, because a reset also drops the transcript.
  def handle_call(:reset, _from, state) do
    close_transport(state)
    if state.timer, do: Process.cancel_timer(state.timer)

    state = %{
      state
      | status: :idle,
        port: nil,
        transport: nil,
        handle: nil,
        buf: "",
        raw_tail: [],
        timer: nil,
        run: nil,
        queue: [],
        session_id: nil
    }

    broadcast(state, {:reset})
    {:reply, :ok, state}
  end

  def handle_call({:barge, id}, _from, state) do
    case Enum.find(state.queue, &(&1.id == id)) do
      nil ->
        {:reply, :ok, state}

      item ->
        # Move the piece to the front, then either cut the running turn (so it runs
        # next) or — if idle — dispatch it straight away.
        state = %{state | queue: [item | Enum.reject(state.queue, &(&1.id == id))]}

        state =
          if state.status == :running,
            do: interrupt_running(state),
            else: dispatch_next(state)

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, buf} = StreamEvent.split_lines(state.buf <> data)
    {:noreply, Enum.reduce(lines, %{state | buf: buf}, &apply_line/2)}
  end

  def handle_info({port, {:exit_status, 0}}, %{port: port} = state),
    do: {:noreply, state |> audit_run(:completed) |> finish_run()}

  # A non-zero exit is a FAILED run. This used to be audited as :completed with
  # nothing on screen — the classic first-run shape (Claude installed but not
  # logged in) looked like the app was broken. Surface what the CLI printed and
  # the likely remedy.
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    state =
      state
      |> emit_message(:error, exit_error_text(code, state.raw_tail))
      |> audit_run({:failed, {:exit_status, code}})

    {:noreply, finish_run(state)}
  end

  def handle_info({:run_timeout, token}, %{status: :running, run: %{token: run_token}} = state)
      when token == run_token do
    interrupt_transport(state)

    state =
      state
      |> emit_message(:error, error_text(:timeout))
      |> audit_run({:failed, :timeout})

    {:noreply, finish_run(%{state | timer: nil})}
  end

  # A stale timeout: it fired as its turn completed (or after a reset/interrupt),
  # so its token no longer matches the in-flight run. Ignore it — otherwise it
  # would false-kill the next turn's fresh run.
  def handle_info({:run_timeout, _token}, state), do: {:noreply, state}

  # Stale messages from a prior run's port.
  def handle_info(_msg, state), do: {:noreply, state}

  # --- run lifecycle ---

  # Spawn a headless run for `text`. Returns `{:ok, state}` once streaming, or
  # `{:error, reason, state}` if the spawn failed (already surfaced + audited).
  defp start_run(state, text) do
    # A per-run token stamps the timeout timer so a stale `:run_timeout` (fired
    # just as its turn ended) can't be mistaken for the next run's timeout.
    token = System.unique_integer([:positive, :monotonic])

    state =
      state
      |> emit_message(:user, text)
      |> Map.put(:run, %{
        token: token,
        started: System.monotonic_time(:millisecond),
        first_token_at: nil,
        turns: nil,
        cost: nil
      })

    # WHICH argv and WHERE the prompt goes are the backend's business, not this
    # module's — see `BusterClaw.Agent.ChatTransport`. `Chat` keeps the decision
    # of which backend (`effective_agent/1` is a security call) and everything
    # downstream of the bytes.
    agent = effective_agent(state)
    transport = state.transport_mod || transport_for(agent)

    {:ok, handle} =
      transport.open(
        # Passed through UNRESOLVED, nil included. `nil` is not "claude" — it is
        # "let `AgentRunner.detect/0` decide", which is what honours the
        # `:agent_cli` override and PATH order. Substituting the adapter's own
        # name here turns detection into a hard `{:agent_unavailable, :claude}`
        # on a machine that only has codex.
        agent: agent,
        session_id: state.session_id,
        append_system_prompt: state.append_system_prompt,
        extra_cli_args: state.extra_cli_args,
        permission_mode: state.permission_mode,
        spawner: state.spawner
      )

    case transport.start_turn(handle, text) do
      {:ok, handle, turn_ref} ->
        broadcast(state, {:status, :running})
        timer = Process.send_after(self(), {:run_timeout, token}, state.timeout_ms)

        {:ok,
         %{
           state
           | status: :running,
             port: turn_ref,
             transport: transport,
             handle: handle,
             buf: "",
             raw_tail: [],
             timer: timer
         }}

      {:error, reason} ->
        state = state |> emit_message(:error, error_text(reason)) |> audit_run({:failed, reason})
        {:error, reason, %{state | run: nil, status: :idle}}
    end
  end

  # Append to the on-deck queue. Dispatched one-per-turn, in order, by
  # `dispatch_next/1`. In-memory only — Phase 6's ledger is what makes an
  # acknowledged message survive a crash.
  defp enqueue(state, text), do: do_enqueue(state, text, :back)

  # The completion race gets the FRONT. The operator aimed this message at work
  # that was happening a moment ago; making it wait behind messages they wrote
  # earlier would reorder their intent. Ordinary queue-next keeps its place in
  # line.
  defp enqueue_front(state, text), do: do_enqueue(state, text, :front)

  defp do_enqueue(state, text, position) do
    item = %{id: System.unique_integer([:positive, :monotonic]), text: text}

    queue =
      case position do
        :front -> [item | state.queue]
        :back -> state.queue ++ [item]
      end

    state = %{state | queue: queue}
    broadcast_queue(state)
    state
  end

  # Try to put `text` into the turn that is already running; fall back to the
  # queue when the backend cannot, or when the turn ended first.
  #
  # The fallback is not a failure path — it is the correct answer to the
  # completion race (roadmap scenario C), and the reason `submit/3` returns the
  # mode that HAPPENED rather than the one requested. Phase 1 always lands here,
  # because no adapter implements `steer/3` yet.
  defp steer_or_queue(%{transport: nil} = state, text),
    do: {:reply, {:ok, :queued}, enqueue(state, text)}

  defp steer_or_queue(state, text) do
    case state.transport.steer(state.handle, state.port, text) do
      {:ok, handle, _receipt} ->
        # A steered message belongs to the active turn: it is persisted and
        # shown as operator input, but it does not start a turn, so nothing
        # here touches `run` or the turn counter.
        state = emit_message(%{state | handle: handle}, :user, text)
        {:reply, {:ok, :steered}, state}

      # The turn ended between the operator hitting send and the adapter being
      # asked. The message is NOT lost and is NOT retried against whatever turn
      # starts next — it becomes the next turn itself, first in line.
      {:error, :no_active_turn} ->
        {:reply, {:ok, :queued}, enqueue_front(state, text)}

      # The backend simply cannot steer. This is an ordinary follow-up turn and
      # takes its place in line.
      {:error, _reason} ->
        {:reply, {:ok, :queued}, enqueue(state, text)}
    end
  end

  # Pull the next queued message into a fresh run, or settle into idle. Skips past
  # an item whose spawn fails so one bad message can't wedge the whole queue.
  defp dispatch_next(%{queue: []} = state) do
    broadcast(state, {:status, :idle})
    # The one settle-into-idle point — every run ending (success, error,
    # timeout, interrupt) funnels here with nothing left queued, which is
    # exactly "the agent went quiet, come look" (SOUND_ROADMAP group A). While
    # the queue still holds work the agent is not done, so no ring above.
    BusterClaw.Notifications.SoundBoard.ring("chat")
    state
  end

  defp dispatch_next(%{queue: [next | rest]} = state) do
    state = %{state | queue: rest}
    broadcast_queue(state)

    case start_run(state, next.text) do
      {:ok, state} -> state
      {:error, _reason, state} -> dispatch_next(state)
    end
  end

  # Kill the in-flight run, mark the turn interrupted, and hand off to the queue
  # (finish_run → dispatch_next). The killed process's later exit/data messages
  # carry the old port, so they no longer match handle_info and are ignored.
  defp interrupt_running(state) do
    interrupt_transport(state)

    state
    |> emit_message(:meta, "interrupted")
    |> audit_run(:interrupted)
    |> finish_run()
  end

  defp apply_line(line, state) do
    # `effective_agent/1`, NOT `state.agent`: a conversation carrying claude-only
    # confinement is SPAWNED as claude even when the operator's harness is codex,
    # so parsing by the stored harness would read claude's stream-json with the
    # codex normalizer. Every event falls through to :unknown and the transcript
    # renders empty — which is exactly how this was found, in the Trading tab.
    # The argv and the parser must come from one function or they drift.
    case StreamEvent.parse(effective_agent(state), line) do
      {:ok, event} -> state |> capture_session(event) |> project_event(event)
      :error -> remember_raw_line(state, line)
    end
  end

  # Newest-first, bounded; rendered (reversed) only when a run fails.
  @raw_tail_lines 12
  defp remember_raw_line(state, line) do
    case String.trim(line) do
      "" ->
        state

      line ->
        %{
          state
          | raw_tail: Enum.take([String.slice(line, 0, 300) | state.raw_tail], @raw_tail_lines)
        }
    end
  end

  defp capture_session(state, %StreamEvent{session_id: id}) when is_binary(id),
    do: %{state | session_id: id, handle: ChatTransport.put_session(state.handle, id)}

  defp capture_session(state, _event), do: state

  defp project_event(state, %StreamEvent{kind: :assistant_text, text: text})
       when is_binary(text) and text != "",
       do: state |> mark_first_token() |> emit_message(:assistant, text)

  defp project_event(state, %StreamEvent{kind: :tool_use, tool: tool} = event)
       when is_binary(tool) do
    if tool in state.audit_tools, do: audit_tool_use(state, event)

    case event.summary do
      summary when is_binary(summary) ->
        state |> mark_first_token() |> emit_message(:tool, summary)

      _ ->
        mark_first_token(state)
    end
  end

  defp project_event(state, %StreamEvent{kind: :tool_use, summary: summary})
       when is_binary(summary),
       do: state |> mark_first_token() |> emit_message(:tool, summary)

  defp project_event(state, %StreamEvent{kind: :result} = event) do
    state = %{state | run: stash_result(state.run, event)}
    state = surface_result_error(state, event)

    case result_meta_line(state.run, event) do
      nil ->
        state

      line ->
        emit_message(state, :meta, line, cost_usd: event.cost_usd, num_turns: event.num_turns)
    end
  end

  defp project_event(state, _event), do: state

  # The first model output (text or a tool call) ends the "thinking" phase. Stamp
  # it once and tell the UI to freeze its live thinking timer at the measured
  # time-to-first-token. A no-op once stamped, or if there's no run in flight.
  defp mark_first_token(%{run: %{first_token_at: nil, started: started} = run} = state) do
    now = System.monotonic_time(:millisecond)
    broadcast(state, {:thinking, now - started})
    %{state | run: %{run | first_token_at: now}}
  end

  defp mark_first_token(state), do: state

  defp stash_result(run, event),
    do:
      Map.merge(run || %{}, %{
        turns: event.num_turns,
        cost: event.cost_usd,
        usage: event.usage
      })

  # End the current run, then hand off to the queue: dispatch_next/1 either starts
  # the next queued turn (staying :running, no idle flicker between turns) or
  # broadcasts :idle when the queue is empty.
  defp finish_run(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    dispatch_next(%{
      state
      | status: :idle,
        port: nil,
        transport: nil,
        handle: nil,
        buf: "",
        timer: nil,
        run: nil
    })
  end

  # Stop the in-flight turn through its own adapter. One-shot backends kill the
  # process group; Phase 2's duplex Claude will interrupt the turn and keep the
  # process. `Chat` deliberately does not know which of those happened — that is
  # the whole point of the boundary.
  #
  # Both helpers fall back to `AgentRunner.kill_port/1` when there is no handle:
  # a run can be in flight with `transport: nil` only if `start_run/2` failed
  # midway, and leaking a process group is worse than a redundant kill.
  defp interrupt_transport(%{transport: nil} = state) do
    if is_port(state.port), do: AgentRunner.kill_port(state.port)
    :ok
  end

  defp interrupt_transport(state) do
    state.transport.interrupt(state.handle, state.port)
    :ok
  end

  defp close_transport(%{transport: nil} = state) do
    if is_port(state.port), do: AgentRunner.kill_port(state.port)
    :ok
  end

  defp close_transport(state) do
    state.transport.close(state.handle)
    :ok
  end

  # Record the run on the Sentinel audit feed (best-effort). This is both the
  # security record of a headless run (chat spawns Claude with bypassPermissions)
  # and the source of the Activity "runs" metric. The message contains "agent
  # run" so `ActivityReport` counts it alongside unattended runs.
  defp audit_run(%{audit?: false} = state, _outcome), do: state

  defp audit_run(state, outcome) do
    run = state.run || %{}
    duration = if run[:started], do: System.monotonic_time(:millisecond) - run[:started]

    {message, severity} =
      case outcome do
        :completed -> {"Chat agent run completed", :info}
        :interrupted -> {"Chat agent run interrupted", :info}
        {:failed, reason} -> {"Chat agent run failed (#{inspect(reason)})", :warning}
      end

    Sentinel.observe(
      :command_invoke,
      message,
      %{
        source: "chat",
        conv_id: state.conv_id,
        session_id: state.session_id,
        num_turns: run[:turns],
        cost_usd: run[:cost],
        # WHICH harness ran it. Without this the feed cannot answer "what was
        # this conversation actually running on", and a cost figure without the
        # harness beside it is not attributable to anything.
        agent: state.agent || :auto,
        usage: run[:usage],
        duration_ms: duration
      },
      severity: severity
    )

    state
  end

  # Broadcast a display-ready transcript entry and persist it (best-effort). The
  # LiveView renders straight from `{:message, msg}`, so formatting lives here
  # once — a reload reproduces the same transcript from the stored content.
  defp emit_message(state, role, text, extra \\ []) do
    msg = %{role: role, text: text}
    broadcast(state, {:message, msg})

    if state.persist? do
      Transcript.record(state.conv_id, role, text, [{:session_id, state.session_id} | extra])
    end

    state
  end

  defp result_meta_line(run, %StreamEvent{cost_usd: cost, num_turns: turns})
       when is_number(cost) and is_integer(turns) do
    [thinking_label(run), "#{turns} turns", "$#{Float.round(cost * 1.0, 4)}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp result_meta_line(_run, _event), do: nil

  defp thinking_label(%{started: started, first_token_at: ft})
       when is_integer(started) and is_integer(ft),
       do: "thought #{format_secs(ft - started)}"

  defp thinking_label(_run), do: nil

  defp format_secs(ms), do: :erlang.float_to_binary(max(ms, 0) / 1000, decimals: 1) <> "s"

  # A well-formed error result (is_error / non-"success" subtype) used to be
  # reduced to its cost meta line — the body that says WHY was discarded. Show it.
  defp surface_result_error(state, %StreamEvent{raw: raw, text: text}) do
    subtype = raw["subtype"]

    if raw["is_error"] == true or (is_binary(subtype) and subtype != "success") do
      emit_message(
        state,
        :error,
        text || "The run ended with an error (#{subtype || "unknown"})."
      )
    else
      state
    end
  end

  defp exit_error_text(code, raw_tail) do
    detail = raw_tail |> Enum.reverse() |> Enum.join("\n") |> String.trim()

    hint =
      cond do
        detail =~ ~r/log ?in|logged out|authenticat|unauthorized|api key|credential/i ->
          "It looks like Claude Code isn't logged in — run `claude login` in a terminal, then try again."

        detail =~ ~r/rate.?limit|quota|overloaded|429/i ->
          "It looks like a rate limit — wait a moment and try again."

        true ->
          nil
      end

    [
      "The agent CLI exited with status #{code} before finishing.",
      hint,
      if(detail != "", do: detail)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp error_text(:timeout), do: "The run timed out and was stopped."
  defp error_text(:no_agent_cli), do: "No agent CLI found. Install Claude Code to chat."
  defp error_text(reason), do: "Run failed: #{inspect(reason)}"

  # Per-harness argv (resume spelling, where the system-prompt guide goes, the
  # streaming flags) moved to `BusterClaw.Agent.ChatTransport.{Claude,Codex,
  # OpenCode}` — one module per protocol, so a JSON-RPC or HTTP backend does not
  # have to pretend to be a flag list. The reasoning that used to live here is
  # preserved in those moduledocs, including why codex gets no resume.

  # The harness → adapter mapping. It lives here rather than on `ChatTransport`
  # because the adapters depend on that module for `@behaviour`, so pointing back
  # at them from there would make the four transport files a dependency cycle.
  #
  # An unknown or unresolved backend reads as claude, the same rule
  # `StreamEvent.parse/2` follows: every caller predates harness selection, and
  # claude's shape is the one they were written against. Note this decides the
  # PROTOCOL only — the agent value itself is passed through unresolved, so `nil`
  # still means "let `AgentRunner.detect/0` choose the binary".
  defp transport_for(:codex), do: ChatTransport.Codex
  defp transport_for(:opencode), do: ChatTransport.OpenCode
  defp transport_for(_claude_or_unknown), do: ChatTransport.Claude

  # A conversation whose profile carries claude-only confinement — the Trading
  # chat's `--strict-mcp-config`/`--allowedTools`, Chart Build's — cannot run
  # anywhere else; those flags are rejected outright, not degraded. Same fact
  # that pins the money surfaces, applied one level up. Silently honouring a
  # harness the run cannot use would fail every turn instead.
  defp effective_agent(%{extra_cli_args: []} = state), do: state.agent
  defp effective_agent(_state), do: :claude

  # The click is what used to leave a record. Without one, this is the record:
  # the tool call itself, as it happens, with the arguments the model passed.
  # `:outbound_send` is the same category the order confirmation uses, because it
  # is the same kind of event — something left this machine for a broker.
  defp audit_tool_use(state, %StreamEvent{tool: tool, tool_input: input}) do
    BusterClaw.Sentinel.observe(
      :outbound_send,
      "Agent used #{tool}",
      %{
        source: "agent_chat_tool",
        conv_id: state.conv_id,
        tool: tool,
        arguments: inspect(input),
        agent: state.agent || :auto
      },
      severity: :warning
    )
  rescue
    # Never let the audit be the thing that takes the run down.
    _error -> :ok
  end

  defp broadcast(state, payload),
    do: PubSub.broadcast(BusterClaw.PubSub, state.topic, {:agent_chat, state.conv_id, payload})

  defp broadcast_queue(state), do: broadcast(state, {:queue, state.queue})

  # The real spawner: open a streaming Port through AgentRunner (login shell, so a
  # packaged-app/daemon run reaches the user's PATH + agent auth).
  #
  # The `:chat` model is resolved HERE, not in `start_run/2`, for two reasons:
  # this is the last moment before the spawn (a run must never inherit a model
  # read at process start — see the AgentMode init regression of 08-03), and the
  # injected-spawner seam that the chat tests use stays free of any DB read.
  # `put_new` so a caller that passed its own `:model` keeps it.
  defp default_spawner(prompt, opts) do
    opts =
      opts
      # The model is resolved per RUN (it does not change the argv shape). The
      # harness is NOT resolved here — it arrives on `opts` from the Chat state,
      # because the stream flags were already built from it and a second
      # resolution could disagree with them.
      |> Keyword.put_new(:model, ModelPolicy.for_surface(:chat))

    case AgentRunner.open(prompt, opts) do
      {:ok, %{port: port}} -> {:ok, port}
      {:error, _reason} = error -> error
    end
  end

  defp configured(key, default), do: Application.get_env(:buster_claw, key, default)
end
