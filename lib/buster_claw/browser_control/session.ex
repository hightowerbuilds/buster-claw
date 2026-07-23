defmodule BusterClaw.BrowserControl.Session do
  @moduledoc """
  One browser session: a single engine process, a single attached target, a
  single profile scope (BROWSER_ENGINE_ROADMAP Phase 2).

  A session owns exactly one `CDP` engine and one page target attached in flat
  mode, so `command/3` needs no `sessionId` from callers — the session carries
  it. One engine per session (not shared tabs) is deliberate: `--user-data-dir`
  is per-engine, so "one profile scope per session" and "one engine per session"
  are the same statement, and it is the isolation the Agent Mode security model
  rests on.

  The session owns its **idle reaper**: while idle it arms a timer, and firing
  terminates the session (which reaps the OS engine via `CDP`'s armed stop). The
  `Pool` drives the lease transitions — `lease/2` stops the clock, `release/1`
  restarts it — so an idle, un-leased session never lingers holding a browser
  process. Engine death is loud: the session subscribes to its `CDP` and stops
  itself the moment the engine exits, rather than serving a dead target.
  """

  use GenServer, restart: :temporary
  require Logger

  alias BusterClaw.BrowserControl.CDP

  @default_idle_ms 60_000
  @attach_timeout_ms 15_000

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Start a session. Options: `:browser_path` (required), `:profile_dir`
  (required), `:headless` (default `true`), `:idle_ms` (default 60s),
  `:id` (opaque label for logs/stats).
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Mark leased to `owner`: stop the idle clock until release."
  def lease(session, owner) when is_pid(session), do: GenServer.cast(session, {:lease, owner})

  @doc "Return to idle: (re)arm the idle reaper."
  def release(session) when is_pid(session), do: GenServer.cast(session, :release)

  @doc """
  Run a CDP command scoped to this session's attached target. Same return
  contract as `CDP.command/4`; `session_id` is supplied automatically.
  """
  def command(session, method, params \\ %{}, opts \\ []) do
    case GenServer.call(session, :handles) do
      {:ok, cdp, sid} -> CDP.command(cdp, method, params, Keyword.put(opts, :session_id, sid))
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _ -> {:error, :session_gone}
  end

  @doc "Navigate the session's target and wait for its load event (or `:timeout`)."
  def navigate(session, url, timeout_ms \\ 15_000) do
    GenServer.call(session, {:navigate, url, timeout_ms}, timeout_ms + 2_000)
  catch
    :exit, _ -> {:error, :session_gone}
  end

  @doc "Snapshot: id, lease state, target/session ids, current url (best-effort)."
  def info(session), do: GenServer.call(session, :info)

  @doc "Stop the session and reap its engine."
  def stop(session), do: GenServer.stop(session, :normal, 10_000)

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    browser = Keyword.fetch!(opts, :browser_path)
    profile = Keyword.fetch!(opts, :profile_dir)
    File.mkdir_p!(profile)

    with {:ok, cdp} <-
           CDP.start_link(
             browser_path: browser,
             profile_dir: profile,
             headless: Keyword.get(opts, :headless, true)
           ),
         :ok <- CDP.subscribe(cdp),
         {:ok, target_id, session_id} <- attach_target(cdp) do
      state = %{
        id: Keyword.get(opts, :id, inspect(self())),
        cdp: cdp,
        target_id: target_id,
        session_id: session_id,
        profile_dir: profile,
        idle_ms: Keyword.get(opts, :idle_ms, @default_idle_ms),
        leased_to: nil,
        idle_timer: nil,
        url: nil
      }

      {:ok, arm_idle(state)}
    else
      {:error, reason} -> {:stop, {:session_init_failed, reason}}
    end
  end

  @impl true
  def handle_call(:handles, _from, state) do
    {:reply, {:ok, state.cdp, state.session_id}, state}
  end

  def handle_call({:navigate, url, timeout_ms}, _from, state) do
    result =
      with {:ok, _} <-
             CDP.command(state.cdp, "Page.enable", %{}, session_id: state.session_id),
           {:ok, _} <-
             CDP.command(state.cdp, "Page.navigate", %{"url" => url},
               session_id: state.session_id,
               timeout: timeout_ms
             ) do
        await_load(state.session_id, timeout_ms)
      end

    case result do
      :ok -> {:reply, :ok, %{state | url: url}}
      other -> {:reply, other, state}
    end
  end

  def handle_call(:info, _from, state) do
    {:reply,
     %{
       id: state.id,
       leased: state.leased_to != nil,
       target_id: state.target_id,
       session_id: state.session_id,
       os_pid: CDP.os_pid(state.cdp),
       url: state.url
     }, state}
  end

  @impl true
  def handle_cast({:lease, owner}, state) do
    {:noreply, %{cancel_idle(state) | leased_to: owner}}
  end

  def handle_cast(:release, state) do
    {:noreply, arm_idle(%{state | leased_to: nil})}
  end

  @impl true
  def handle_info(:idle_reap, %{leased_to: nil} = state) do
    # Idle and un-leased for the whole window: give the browser process back.
    {:stop, :normal, state}
  end

  def handle_info(:idle_reap, state), do: {:noreply, state}

  def handle_info({:browser_control_exit, status}, state) do
    # The engine died out from under us — never serve a dead target.
    Logger.warning("browser_control: session #{state.id} engine exited (#{inspect(status)})")
    {:stop, :normal, state}
  end

  def handle_info({:browser_control_event, _method, _params, _sid}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Reap the engine on every exit path (idle reap, crash, supervisor shutdown).
    if is_pid(state[:cdp]) and Process.alive?(state.cdp), do: CDP.stop(state.cdp)
    :ok
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp attach_target(cdp) do
    with {:ok, %{"targetId" => target_id}} <-
           CDP.command(cdp, "Target.createTarget", %{"url" => "about:blank"},
             timeout: @attach_timeout_ms
           ),
         {:ok, %{"sessionId" => session_id}} <-
           CDP.command(
             cdp,
             "Target.attachToTarget",
             %{"targetId" => target_id, "flatten" => true},
             timeout: @attach_timeout_ms
           ) do
      {:ok, target_id, session_id}
    end
  end

  defp await_load(session_id, timeout_ms) do
    receive do
      {:browser_control_event, "Page.loadEventFired", _p, ^session_id} -> :ok
    after
      timeout_ms -> {:error, :load_timeout}
    end
  end

  defp arm_idle(state) do
    state = cancel_idle(state)
    %{state | idle_timer: Process.send_after(self(), :idle_reap, state.idle_ms)}
  end

  defp cancel_idle(%{idle_timer: nil} = state), do: state

  defp cancel_idle(%{idle_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | idle_timer: nil}
  end
end
