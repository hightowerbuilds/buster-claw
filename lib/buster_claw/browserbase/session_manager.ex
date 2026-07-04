defmodule BusterClaw.Browserbase.SessionManager do
  @moduledoc """
  Owns the lifecycle of Browserbase cloud browser sessions in the BEAM.

  A session is expensive — it bills per browser-minute — so this process is the
  cost guardrail: it caps concurrency, reaps idle and over-age sessions on a
  timer, and releases everything it holds on graceful shutdown. Nothing opens a
  session it can't guarantee to close.

  The manager holds only session *metadata* (ids, the CDP `connect_url`, the
  live-view URL, timestamps). The session is *driven* over CDP by the Node
  sidecar; this process never touches the page. Callers `open/1` a session, pass
  the returned `session_id` back on every primitive (the stateless CLI threads
  it through), `touch/1` it to defer the idle clock, and `close/1` when done.

  ## Concurrency model — keep the loop responsive, keep the registry serialized

  `touch/checkout` run on *every* web primitive, so the GenServer loop must never
  block on the network. Only the session registry, the idle clocks, and the cost
  guardrails live in GenServer state and are mutated exclusively via messages;
  all blocking HTTP is pushed onto a per-manager `Task.Supervisor` (started in
  `init/1`, linked):

    * `open` replies *asynchronously*. `handle_call(:open, ...)` reserves a slot
      (in-flight opens are tracked in `:opening` and count toward
      `max_concurrent` so a slow open can never breach the cap), spawns a
      monitored task for the 3 sequential network calls, and returns `:noreply`.
      The task's result comes back as a message; only then is the session
      recorded and the caller replied to.
    * `close` and the `:sweep` reaper remove the session from the registry
      *synchronously* (so it is forgotten exactly once) and fire the actual
      cloud release on a supervised task. Forget-once semantics match the old
      code: a failed release is logged, never retried, and the cloud session is
      backstopped by Browserbase's own idle timeout.

  ## Known gap (durable records — Phase 0.3 follow-up)

  Session records are in-memory only. A graceful stop releases them; a hard VM
  crash orphans whatever cloud sessions were open until Browserbase's own
  timeout expires them. Durable records + boot-time reaping close that gap and
  are tracked as the next 0.3 increment.
  """

  use GenServer

  require Logger

  alias BusterClaw.Browser.SessionClient
  alias BusterClaw.Browserbase

  @default_idle_timeout_ms :timer.minutes(5)
  @default_max_lifetime_ms :timer.minutes(30)
  @default_max_concurrent 5
  @default_sweep_interval_ms :timer.seconds(30)

  # Per-session release cap on graceful shutdown. terminate/2 releases every held
  # session concurrently, so total shutdown work is bounded by roughly this cap
  # plus overhead. The supervisor's `shutdown:` window (application.ex) must
  # exceed it, or the manager is brutally killed mid-release and orphans a paid
  # session. Keep the two in sync.
  @shutdown_release_timeout_ms :timer.seconds(20)

  # --- public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Open a cloud session. Creates it via the Browserbase client, fetches its
  live-view URL, and starts its idle clock. Returns the handle the caller (and
  the agent) threads through subsequent primitives.

  Replies asynchronously: the network I/O runs off the GenServer loop, so other
  sessions' touch/checkout stay responsive while an open is in flight.
  """
  @spec open(keyword()) ::
          {:ok,
           %{session_id: String.t(), live_view_url: String.t() | nil, connect_url: String.t()}}
          | {:error, term()}
  def open(opts \\ []) do
    GenServer.call(server(opts), :open, 60_000)
  end

  @doc "Defer a session's idle clock. Call on every primitive that uses it."
  def touch(session_id, opts \\ []) when is_binary(session_id) do
    GenServer.call(server(opts), {:touch, session_id})
  end

  @doc "Fetch a session's metadata (including connect_url for the sidecar)."
  def get(session_id, opts \\ []) when is_binary(session_id) do
    GenServer.call(server(opts), {:get, session_id})
  end

  @doc """
  Resolve a session's sidecar-driver id and defer its idle clock in one call —
  the seam the `Session` facade uses before every primitive.
  """
  def checkout(session_id, opts \\ []) when is_binary(session_id) do
    GenServer.call(server(opts), {:checkout, session_id})
  end

  @doc "Release a session now and forget it. Idempotent."
  def close(session_id, opts \\ []) when is_binary(session_id) do
    GenServer.call(server(opts), {:close, session_id}, 60_000)
  end

  @doc "List open sessions (public metadata only)."
  def list(opts \\ []) do
    GenServer.call(server(opts), :list)
  end

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)

  # --- GenServer ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    # A per-manager supervisor for the blocking HTTP tasks (open network I/O and
    # cloud releases). Linked, so it is torn down with the manager; alive
    # throughout terminate/2 (the manager only exits *after* terminate returns),
    # which is where the shutdown release sweep runs.
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    state = %{
      client: Keyword.get(opts, :client, Browserbase),
      session_client: Keyword.get(opts, :session_client, SessionClient),
      client_opts: Keyword.get(opts, :client_opts, []),
      task_supervisor: task_supervisor,
      sessions: %{},
      # ref => {from, %Task{}} for opens whose network I/O is still running.
      opening: %{},
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, @default_idle_timeout_ms),
      max_lifetime_ms: Keyword.get(opts, :max_lifetime_ms, @default_max_lifetime_ms),
      max_concurrent: Keyword.get(opts, :max_concurrent, @default_max_concurrent),
      sweep_interval_ms: Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)
    }

    schedule_sweep(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:open, from, state) do
    # In-flight opens count toward the cap: a slow open must never let concurrent
    # callers breach max_concurrent (and start paid sessions we didn't budget).
    if map_size(state.sessions) + map_size(state.opening) >= state.max_concurrent do
      {:reply, {:error, :max_sessions}, state}
    else
      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn -> create_session(state) end)

      {:noreply, %{state | opening: Map.put(state.opening, task.ref, {from, task})}}
    end
  end

  def handle_call({:touch, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} ->
        session = %{session | last_used_at: now_ms()}
        {:reply, :ok, put_in(state.sessions[session_id], session)}

      :error ->
        {:reply, {:error, :unknown_session}, state}
    end
  end

  def handle_call({:get, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} -> {:reply, {:ok, public(session)}, state}
      :error -> {:reply, {:error, :unknown_session}, state}
    end
  end

  def handle_call({:checkout, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{sidecar_id: sidecar_id} = session} when is_binary(sidecar_id) ->
        touched = %{session | last_used_at: now_ms()}
        {:reply, {:ok, sidecar_id}, put_in(state.sessions[session_id], touched)}

      _ ->
        {:reply, {:error, :unknown_session}, state}
    end
  end

  def handle_call({:close, session_id}, _from, state) do
    # Forget synchronously (frees the slot, guarantees a single release), then
    # release the paid session off the loop.
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} ->
        release_async(session, state)
        {:reply, :ok, forget(session_id, state)}

      :error ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Enum.map(Map.values(state.sessions), &public/1), state}
  end

  # An open task finished. Record the session (or surface the error) and reply to
  # the waiting caller. The result mutates state here, in the serialized loop —
  # only the network I/O ran off it.
  @impl true
  def handle_info({ref, result}, state) when is_map_key(state.opening, ref) do
    Process.demonitor(ref, [:flush])
    {{from, _task}, opening} = Map.pop(state.opening, ref)
    state = %{state | opening: opening}

    case result do
      {:ok, session} ->
        GenServer.reply(from, {:ok, public_handle(session)})
        {:noreply, put_in(state.sessions[session.id], session)}

      {:error, reason} ->
        GenServer.reply(from, {:error, reason})
        {:noreply, state}
    end
  end

  # An open task crashed before returning. Free the reserved slot and fail the
  # caller rather than leaking the slot forever (which would shrink capacity).
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.opening, ref) do
    {{from, _task}, opening} = Map.pop(state.opening, ref)
    Logger.error("Browserbase open task crashed before returning: #{inspect(reason)}")
    GenServer.reply(from, {:error, {:open_failed, reason}})
    {:noreply, %{state | opening: opening}}
  end

  def handle_info(:sweep, state) do
    now = now_ms()

    {stale, kept} =
      state.sessions
      |> Map.values()
      |> Enum.split_with(&stale?(&1, now, state))

    for s <- stale do
      Logger.info("Reaping Browserbase session #{s.id} (idle/over-age)")
      release_async(s, state)
    end

    state = %{state | sessions: Map.new(kept, &{&1.id, &1})}
    schedule_sweep(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Reply to and stop any in-flight opens. A session one already created but
    # hasn't reported back is a narrow orphan window; Browserbase's own idle
    # timeout backstops it (see the "durable records" gap above).
    for {_ref, {from, task}} <- state.opening do
      Process.exit(task.pid, :kill)
      GenServer.reply(from, {:error, :shutting_down})
    end

    # Release every held session concurrently, each capped so the whole sweep
    # fits inside the supervisor's shutdown window (application.ex) and the
    # manager is never brutally killed mid-release, orphaning a paid browser.
    case Map.values(state.sessions) do
      [] ->
        :ok

      sessions ->
        state.task_supervisor
        |> Task.Supervisor.async_stream_nolink(
          sessions,
          fn session -> release_session(session, state) end,
          max_concurrency: length(sessions),
          timeout: @shutdown_release_timeout_ms,
          on_timeout: :kill_task,
          ordered: false
        )
        |> Stream.run()
    end

    :ok
  end

  # --- internals ---

  # Pure network path: create the session, fetch its live-view URL, hand it to
  # the sidecar. Runs inside an open task — touches no GenServer state; returns
  # the session map (recorded by the loop) or an error.
  defp create_session(state) do
    with {:ok, created} <- state.client.create(state.client_opts),
         {:ok, dbg} <- state.client.debug(created.id, state.client_opts),
         {:ok, sidecar_id} <- open_sidecar(state, created) do
      now = now_ms()

      {:ok,
       %{
         id: created.id,
         sidecar_id: sidecar_id,
         connect_url: created.connect_url,
         live_view_url: dbg.live_view_url,
         opened_at: now,
         last_used_at: now
       }}
    end
  end

  # Hand the session's connect_url to the sidecar to drive. If the sidecar can't
  # take it, release the paid Browserbase session immediately — never leave a
  # cloud browser we can't drive still billing.
  defp open_sidecar(state, created) do
    case state.session_client.open(created.connect_url, state.client_opts) do
      {:ok, body} ->
        {:ok, body["id"] || body[:id]}

      {:error, reason} ->
        state.client.release(created.id, state.client_opts)
        {:error, {:sidecar_open_failed, reason}}
    end
  end

  # Fire the sidecar-close + cloud-release for a forgotten session on a task, so
  # close/sweep never block the loop on the network.
  defp release_async(session, state) do
    Task.Supervisor.start_child(state.task_supervisor, fn -> release_session(session, state) end)
    :ok
  end

  # The blocking release itself — close the sidecar handle, then release the
  # paid cloud session. Best-effort: a failure is logged, never retried.
  defp release_session(session, state) do
    if session.sidecar_id do
      state.session_client.close(session.sidecar_id, state.client_opts)
    end

    case state.client.release(session.id, state.client_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to release #{session.id}: #{inspect(reason)}")
    end
  end

  defp forget(session_id, state), do: %{state | sessions: Map.delete(state.sessions, session_id)}

  defp stale?(session, now, state) do
    now - session.last_used_at > state.idle_timeout_ms or
      now - session.opened_at > state.max_lifetime_ms
  end

  defp public(session) do
    Map.take(session, [:id, :connect_url, :live_view_url, :opened_at, :last_used_at])
  end

  defp public_handle(session) do
    %{
      session_id: session.id,
      live_view_url: session.live_view_url,
      connect_url: session.connect_url
    }
  end

  defp schedule_sweep(state), do: Process.send_after(self(), :sweep, state.sweep_interval_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
