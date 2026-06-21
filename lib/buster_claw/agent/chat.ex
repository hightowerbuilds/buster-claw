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

  alias BusterClaw.AgentRunner
  alias BusterClaw.Agent.StreamEvent
  alias BusterClaw.Agent.Transcript
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

  @doc """
  Ensure a conversation's chat process is running (started lazily under the
  DynamicSupervisor), returning `{:ok, pid}`. Idempotent and race-safe.
  """
  def ensure_started(conv_id) when is_binary(conv_id) do
    case whereis(conv_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        try do
          case DynamicSupervisor.start_child(@supervisor, {__MODULE__, conv_id: conv_id}) do
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
      timer: nil,
      timeout_ms:
        Keyword.get(opts, :timeout_ms, configured(:agent_chat_timeout_ms, @default_timeout_ms)),
      persist?: Keyword.get(opts, :persist, configured(:agent_chat_persist, true)),
      audit?: Keyword.get(opts, :audit, configured(:agent_chat_audit, true)),
      # Tracks the in-flight run for the Sentinel audit event on completion.
      run: nil,
      # Injectable for tests: `spawner.(prompt, opts) :: {:ok, port} | {:error, reason}`.
      spawner: Keyword.get(opts, :spawner, &default_spawner/2)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:send, _text}, _from, %{status: :running} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:send, text}, _from, state) do
    state =
      state
      |> emit_message(:user, text)
      |> Map.put(:run, %{started: System.monotonic_time(:millisecond), turns: nil, cost: nil})

    extra = ~w(--output-format stream-json --verbose) ++ resume_args(state.session_id)

    case state.spawner.(text, extra_args: extra, login: true) do
      {:ok, port} ->
        broadcast(state, {:status, :running})
        timer = Process.send_after(self(), :run_timeout, state.timeout_ms)
        {:reply, :ok, %{state | status: :running, port: port, buf: "", timer: timer}}

      {:error, reason} ->
        state |> emit_message(:error, error_text(reason)) |> audit_run({:failed, reason})
        {:reply, {:error, reason}, %{state | run: nil}}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, buf} = StreamEvent.split_lines(state.buf <> data)
    {:noreply, Enum.reduce(lines, %{state | buf: buf}, &apply_line/2)}
  end

  def handle_info({port, {:exit_status, _code}}, %{port: port} = state),
    do: {:noreply, state |> audit_run(:completed) |> finish_run()}

  def handle_info(:run_timeout, %{status: :running} = state) do
    if is_port(state.port), do: AgentRunner.kill_port(state.port)

    state =
      state
      |> emit_message(:error, error_text(:timeout))
      |> audit_run({:failed, :timeout})

    {:noreply, finish_run(%{state | timer: nil})}
  end

  # Stale messages from a prior run's port, or :run_timeout while idle.
  def handle_info(_msg, state), do: {:noreply, state}

  # --- run lifecycle ---

  defp apply_line(line, state) do
    case StreamEvent.parse(line) do
      {:ok, event} -> state |> capture_session(event) |> project_event(event)
      :error -> state
    end
  end

  defp capture_session(state, %StreamEvent{session_id: id}) when is_binary(id),
    do: %{state | session_id: id}

  defp capture_session(state, _event), do: state

  defp project_event(state, %StreamEvent{kind: :assistant_text, text: text})
       when is_binary(text) and text != "",
       do: emit_message(state, :assistant, text)

  defp project_event(state, %StreamEvent{kind: :tool_use, summary: summary})
       when is_binary(summary),
       do: emit_message(state, :tool, summary)

  defp project_event(state, %StreamEvent{kind: :result} = event) do
    state = %{state | run: stash_result(state.run, event)}

    case result_meta_line(event) do
      nil ->
        state

      line ->
        emit_message(state, :meta, line, cost_usd: event.cost_usd, num_turns: event.num_turns)
    end
  end

  defp project_event(state, _event), do: state

  defp stash_result(run, event),
    do: Map.merge(run || %{}, %{turns: event.num_turns, cost: event.cost_usd})

  defp finish_run(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    broadcast(state, {:status, :idle})
    %{state | status: :idle, port: nil, buf: "", timer: nil, run: nil}
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

  defp result_meta_line(%StreamEvent{cost_usd: cost, num_turns: turns})
       when is_number(cost) and is_integer(turns),
       do: "#{turns} turns · $#{Float.round(cost * 1.0, 4)}"

  defp result_meta_line(_event), do: nil

  defp error_text(:timeout), do: "The run timed out and was stopped."
  defp error_text(:no_agent_cli), do: "No agent CLI found. Install Claude Code to chat."
  defp error_text(reason), do: "Run failed: #{inspect(reason)}"

  defp resume_args(nil), do: []
  defp resume_args(session_id), do: ["--resume", session_id]

  defp broadcast(state, payload),
    do: PubSub.broadcast(BusterClaw.PubSub, state.topic, {:agent_chat, state.conv_id, payload})

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
