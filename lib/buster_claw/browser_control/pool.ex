defmodule BusterClaw.BrowserControl.Pool do
  @moduledoc """
  The session pool — the only door to the engine (BROWSER_ENGINE_ROADMAP Phase 2).

  No socket, no external API: callers reach a browser only by `checkout/1` (or
  `with_session/2`) through the supervision tree, which is what keeps "the
  session never leaves the machine" true by construction rather than by policy.

  Responsibilities:

    * **Cap.** At most `:max_sessions` engines exist at once (default 3 — this is
      agent-only, "a few sessions"). Checkout past the cap with none free is
      `{:error, :pool_exhausted}`, never an unbounded fan of Chrome processes.
    * **Lazy start.** Sessions are born on demand and reused; an idle one is
      handed out before a new one is spawned.
    * **Leases that survive a dead lessee.** Each checkout monitors its owner;
      if the owner crashes mid-task the session is auto-released, so a caller
      blowing up can't strand a browser as permanently busy.
    * **Cleanup.** A session that dies (engine crash, idle reap, wedge) is
      monitored and dropped from every structure — a leaked entry can't
      masquerade as capacity.

  `:no_browser` (no Chromium-family engine installed) surfaces loudly on
  checkout; the pool never degrades to a weaker path.

  Test seam: `:session_mod` (default `SessionSupervisor`) provides
  `start_session/1`, and `:lease_mod` (default `Session`) provides
  `lease/2` + `release/1`, so the leasing/cap/crash logic is exercised with stub
  processes and no real browser.
  """
  use GenServer

  alias BusterClaw.BrowserControl
  alias BusterClaw.BrowserControl.{Session, SessionSupervisor}

  @default_max 3

  defmodule S do
    @moduledoc false
    # available: MapSet of idle session pids
    # leased:    %{session_pid => {owner_pid, owner_ref}}
    # sessions:  MapSet of all live session pids (available ∪ leased keys)
    # monitors:  %{monitor_ref => {:session, pid} | {:owner, session_pid}}
    defstruct max: 3,
              browser_path: nil,
              headless: true,
              idle_ms: 60_000,
              available: MapSet.new(),
              leased: %{},
              sessions: MapSet.new(),
              monitors: %{},
              session_mod: SessionSupervisor,
              lease_mod: Session
  end

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    # Name defaults to the module; tests pass `name: nil` for isolated instances.
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Lease a session for the calling process: `{:ok, session_pid}`,
  `{:error, :pool_exhausted}` (cap reached, none free), or
  `{:error, :no_browser}` (no engine installed). The lease is bound to the
  caller and auto-released if the caller dies.
  """
  def checkout(server \\ __MODULE__), do: GenServer.call(server, {:checkout, self()}, 30_000)

  @doc "Return a leased session to the idle set."
  def checkin(server \\ __MODULE__, session), do: GenServer.call(server, {:checkin, session})

  @doc """
  Bracket: checkout → run `fun.(session)` → checkin (even on raise). Returns the
  function's value, or `{:error, reason}` if no session could be leased.
  """
  def with_session(server \\ __MODULE__, fun) when is_function(fun, 1) do
    case checkout(server) do
      {:ok, session} ->
        try do
          fun.(session)
        after
          checkin(server, session)
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "Counts: `%{total, available, leased, max}`."
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok,
     %S{
       max: Keyword.get(opts, :max_sessions, @default_max),
       browser_path: Keyword.get(opts, :browser_path),
       headless: Keyword.get(opts, :headless, true),
       idle_ms: Keyword.get(opts, :idle_ms, 60_000),
       session_mod: Keyword.get(opts, :session_mod, SessionSupervisor),
       lease_mod: Keyword.get(opts, :lease_mod, Session)
     }}
  end

  @impl true
  def handle_call({:checkout, owner}, _from, state) do
    case take_available(state) do
      {:ok, session, state} ->
        {:reply, {:ok, session}, grant(state, session, owner)}

      :empty ->
        if MapSet.size(state.sessions) >= state.max do
          {:reply, {:error, :pool_exhausted}, state}
        else
          start_and_grant(state, owner)
        end
    end
  end

  def handle_call({:checkin, session}, _from, state), do: {:reply, :ok, release(state, session)}

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       total: MapSet.size(state.sessions),
       available: MapSet.size(state.available),
       leased: map_size(state.leased),
       max: state.max
     }, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {{:session, session}, monitors} ->
        {:noreply, forget_session(%{state | monitors: monitors}, session)}

      {{:owner, session}, monitors} ->
        # The lessee died holding a lease — reclaim the session as idle.
        {:noreply, release(%{state | monitors: monitors}, session, demonitor_owner: false)}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── lease mechanics ──────────────────────────────────────────────────────────

  defp take_available(state) do
    case Enum.take(state.available, 1) do
      [session] -> {:ok, session, %{state | available: MapSet.delete(state.available, session)}}
      [] -> :empty
    end
  end

  defp start_and_grant(state, owner) do
    case resolve_browser(state) do
      {:ok, browser} ->
        opts = [
          browser_path: browser,
          profile_dir: ephemeral_profile(),
          headless: state.headless,
          idle_ms: state.idle_ms
        ]

        case state.session_mod.start_session(opts) do
          {:ok, session} ->
            ref = Process.monitor(session)

            state = %{
              state
              | sessions: MapSet.put(state.sessions, session),
                monitors: Map.put(state.monitors, ref, {:session, session})
            }

            {:reply, {:ok, session}, grant(state, session, owner)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Attach `owner` to `session`: notify the session, monitor the owner so its
  # death releases the lease.
  defp grant(state, session, owner) do
    state.lease_mod.lease(session, owner)
    ref = Process.monitor(owner)

    %{
      state
      | leased: Map.put(state.leased, session, {owner, ref}),
        monitors: Map.put(state.monitors, ref, {:owner, session})
    }
  end

  defp release(state, session, opts \\ []) do
    case Map.pop(state.leased, session) do
      {nil, _} ->
        state

      {{_owner, owner_ref}, leased} ->
        monitors =
          if Keyword.get(opts, :demonitor_owner, true) do
            Process.demonitor(owner_ref, [:flush])
            Map.delete(state.monitors, owner_ref)
          else
            Map.delete(state.monitors, owner_ref)
          end

        state = %{state | leased: leased, monitors: monitors}
        # Only return a still-live session to the idle set.
        if MapSet.member?(state.sessions, session) do
          state.lease_mod.release(session)
          %{state | available: MapSet.put(state.available, session)}
        else
          state
        end
    end
  end

  # A session process died: purge it everywhere and drop its owner monitor.
  defp forget_session(state, session) do
    {owner_entry, leased} = Map.pop(state.leased, session)

    monitors =
      case owner_entry do
        {_owner, owner_ref} ->
          Process.demonitor(owner_ref, [:flush])
          Map.delete(state.monitors, owner_ref)

        nil ->
          state.monitors
      end

    %{
      state
      | sessions: MapSet.delete(state.sessions, session),
        available: MapSet.delete(state.available, session),
        leased: leased,
        monitors: monitors
    }
  end

  defp resolve_browser(%S{browser_path: path}) when is_binary(path), do: {:ok, path}
  defp resolve_browser(_state), do: BrowserControl.detect()

  defp ephemeral_profile do
    Path.join(System.tmp_dir!(), "bc_session_#{System.unique_integer([:positive])}")
  end
end
