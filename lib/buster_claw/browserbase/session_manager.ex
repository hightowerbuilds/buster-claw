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

  # --- public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Open a cloud session. Creates it via the Browserbase client, fetches its
  live-view URL, and starts its idle clock. Returns the handle the caller (and
  the agent) threads through subsequent primitives.
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

    state = %{
      client: Keyword.get(opts, :client, Browserbase),
      session_client: Keyword.get(opts, :session_client, SessionClient),
      client_opts: Keyword.get(opts, :client_opts, []),
      sessions: %{},
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, @default_idle_timeout_ms),
      max_lifetime_ms: Keyword.get(opts, :max_lifetime_ms, @default_max_lifetime_ms),
      max_concurrent: Keyword.get(opts, :max_concurrent, @default_max_concurrent),
      sweep_interval_ms: Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)
    }

    schedule_sweep(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:open, _from, state) do
    if map_size(state.sessions) >= state.max_concurrent do
      {:reply, {:error, :max_sessions}, state}
    else
      case do_open(state) do
        {:ok, session, state} ->
          {:reply,
           {:ok,
            %{
              session_id: session.id,
              live_view_url: session.live_view_url,
              connect_url: session.connect_url
            }}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
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
    {:reply, :ok, release_and_forget(session_id, state)}
  end

  def handle_call(:list, _from, state) do
    {:reply, Enum.map(Map.values(state.sessions), &public/1), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now_ms()

    stale =
      state.sessions
      |> Map.values()
      |> Enum.filter(fn s ->
        now - s.last_used_at > state.idle_timeout_ms or
          now - s.opened_at > state.max_lifetime_ms
      end)

    state =
      Enum.reduce(stale, state, fn s, acc ->
        Logger.info("Reaping Browserbase session #{s.id} (idle/over-age)")
        release_and_forget(s.id, acc)
      end)

    schedule_sweep(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Best-effort: close the sidecar handle and release every session we hold so
    # a graceful stop never leaks a paid cloud browser.
    for {id, session} <- state.sessions do
      if session.sidecar_id do
        state.session_client.close(session.sidecar_id, state.client_opts)
      end

      state.client.release(id, state.client_opts)
    end

    :ok
  end

  # --- internals ---

  defp do_open(state) do
    with {:ok, created} <- state.client.create(state.client_opts),
         {:ok, dbg} <- state.client.debug(created.id, state.client_opts),
         {:ok, sidecar_id} <- open_sidecar(state, created) do
      now = now_ms()

      session = %{
        id: created.id,
        sidecar_id: sidecar_id,
        connect_url: created.connect_url,
        live_view_url: dbg.live_view_url,
        opened_at: now,
        last_used_at: now
      }

      {:ok, session, put_in(state.sessions[created.id], session)}
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

  defp release_and_forget(session_id, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} ->
        if session.sidecar_id do
          state.session_client.close(session.sidecar_id, state.client_opts)
        end

        case state.client.release(session.id, state.client_opts) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to release #{session_id}: #{inspect(reason)}")
        end

      :error ->
        :ok
    end

    %{state | sessions: Map.delete(state.sessions, session_id)}
  end

  defp public(session) do
    Map.take(session, [:id, :connect_url, :live_view_url, :opened_at, :last_used_at])
  end

  defp schedule_sweep(state), do: Process.send_after(self(), :sweep, state.sweep_interval_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
