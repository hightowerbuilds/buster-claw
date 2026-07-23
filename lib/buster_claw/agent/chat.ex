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

  alias BusterClaw.Agent.StreamEvent
  alias BusterClaw.Agent.Transcript
  alias BusterClaw.AgentRunner
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
    with {:ok, _pid} <- ensure_started(conv_id) do
      GenServer.call(via(conv_id), {:send, text})
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
      # Injectable for tests: `spawner.(prompt, opts) :: {:ok, port} | {:error, reason}`.
      spawner: Keyword.get(opts, :spawner, &default_spawner/2)
    }

    {:ok, state}
  end

  # A run is already in flight: queue the message instead of rejecting it. It is
  # dispatched as its own turn when the current run finishes (see dispatch_next/1).
  # The queue is in-memory only — items not yet sent are dropped on restart.
  @impl true
  def handle_call({:send, text}, _from, %{status: :running} = state) do
    item = %{id: System.unique_integer([:positive, :monotonic]), text: text}
    state = %{state | queue: state.queue ++ [item]}
    broadcast_queue(state)
    {:reply, :ok, state}
  end

  def handle_call({:send, text}, _from, state) do
    case start_run(state, text) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
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
    if is_port(state.port), do: AgentRunner.kill_port(state.port)
    if state.timer, do: Process.cancel_timer(state.timer)

    state = %{
      state
      | status: :idle,
        port: nil,
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
    if is_port(state.port), do: AgentRunner.kill_port(state.port)

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

    extra =
      ~w(--output-format stream-json --verbose) ++
        resume_args(state.session_id) ++
        append_system_prompt_args(state.append_system_prompt) ++
        state.extra_cli_args

    case state.spawner.(text, extra_args: extra, login: true) do
      {:ok, port} ->
        broadcast(state, {:status, :running})
        timer = Process.send_after(self(), {:run_timeout, token}, state.timeout_ms)
        {:ok, %{state | status: :running, port: port, buf: "", raw_tail: [], timer: timer}}

      {:error, reason} ->
        state = state |> emit_message(:error, error_text(reason)) |> audit_run({:failed, reason})
        {:error, reason, %{state | run: nil, status: :idle}}
    end
  end

  # Pull the next queued message into a fresh run, or settle into idle. Skips past
  # an item whose spawn fails so one bad message can't wedge the whole queue.
  defp dispatch_next(%{queue: []} = state) do
    broadcast(state, {:status, :idle})
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
    if is_port(state.port), do: AgentRunner.kill_port(state.port)

    state
    |> emit_message(:meta, "interrupted")
    |> audit_run(:interrupted)
    |> finish_run()
  end

  defp apply_line(line, state) do
    case StreamEvent.parse(line) do
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
    do: %{state | session_id: id}

  defp capture_session(state, _event), do: state

  defp project_event(state, %StreamEvent{kind: :assistant_text, text: text})
       when is_binary(text) and text != "",
       do: state |> mark_first_token() |> emit_message(:assistant, text)

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
    do: Map.merge(run || %{}, %{turns: event.num_turns, cost: event.cost_usd})

  # End the current run, then hand off to the queue: dispatch_next/1 either starts
  # the next queued turn (staying :running, no idle flicker between turns) or
  # broadcasts :idle when the queue is empty.
  defp finish_run(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    dispatch_next(%{state | status: :idle, port: nil, buf: "", timer: nil, run: nil})
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

  defp resume_args(nil), do: []
  defp resume_args(session_id), do: ["--resume", session_id]

  defp append_system_prompt_args(nil), do: []
  defp append_system_prompt_args(""), do: []
  defp append_system_prompt_args(prompt), do: ["--append-system-prompt", prompt]

  defp broadcast(state, payload),
    do: PubSub.broadcast(BusterClaw.PubSub, state.topic, {:agent_chat, state.conv_id, payload})

  defp broadcast_queue(state), do: broadcast(state, {:queue, state.queue})

  # The real spawner: open a streaming Port through AgentRunner (login shell, so a
  # packaged-app/daemon run reaches the user's PATH + agent auth).
  defp default_spawner(prompt, opts) do
    case AgentRunner.open(prompt, opts) do
      {:ok, %{port: port}} -> {:ok, port}
      {:error, _reason} = error -> error
    end
  end

  defp configured(key, default), do: Application.get_env(:buster_claw, key, default)
end
