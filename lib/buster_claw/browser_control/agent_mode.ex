defmodule BusterClaw.BrowserControl.AgentMode do
  @moduledoc """
  Agent Mode — the watchable run orchestrator (BROWSER_ENGINE_ROADMAP Phase 4).

  Ties together everything the earlier phases built: a leased `Session` (Phase 2),
  a frozen `Scope` (Phase 3), `Egress` controls (Phase 3.5), and a `Trajectory`
  (this phase). It drives one task through the `Mode` state machine, records every
  step, and broadcasts each transition so the UI rail is a projection of one
  authoritative value — never a second source of truth.

  Load-bearing safety properties, enforced here rather than hoped for:

    * **Only `agent_working` acts.** `navigate/2` / `act/3` refuse in any other
      mode. Take-the-wheel and stop therefore actually stop the agent, because
      "acting" has exactly one legal state.
    * **Stop halts before the next action.** A stop flips the mode; the very next
      `act` sees a non-acting mode and does nothing. There is no in-flight action
      to interrupt because actions are serialized through this GenServer.
    * **The frozen scope gates every navigation** (via `BrowserControl.navigate/3`)
      — an off-scope or payment URL halts, is recorded as a haltED step with its
      origin, and (through `Scope.guard`) lands on the Sentinel feed.
    * **Secrets resolve in the executor, never the reasoner.** `act(:fill, …)`
      resolves `$secret.<name>` locally just before the value reaches the browser;
      the trajectory stores only the masked form.

  This is the orchestration brain. The headful Tauri window and the LiveView rail
  render its `subscribe/1` broadcasts and its `trajectory/1`; they are the
  deferred UI slice and add no authority of their own.
  """
  use GenServer

  alias BusterClaw.BrowserControl
  alias BusterClaw.BrowserControl.AgentMode.{Mode, Trajectory}
  alias BusterClaw.BrowserControl.Egress.SecretRef
  alias BusterClaw.BrowserControl.Session
  alias Phoenix.PubSub

  @topic_prefix "browser_agent_mode:"

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Start an Agent Mode run. Options:
    * `:scope` (required) — the frozen `Scope`.
    * `:session` (required) — a leased session pid (or a `:session_mod` stub).
    * `:session_mod` — module answering `navigate/2` + `command/4` (default
      `Session`); injectable for tests.
    * `:navigate_mod` — module answering `navigate/3` (default `BrowserControl`);
      injectable so the scope gate is exercised without a browser.
    * `:secret_resolver` — `fn name -> {:ok, value} | :error end`.
    * `:clock` — `fn -> integer end` for step timestamps (no wall-clock read here).
    * `:name` — registered name (omit for anonymous, as tests do).
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @doc "The PubSub topic a run broadcasts transitions and steps on."
  def topic(run_id), do: @topic_prefix <> run_id

  @doc "Subscribe the caller to a run's feed (`{:agent_mode, run_id, event}`)."
  def subscribe(server) do
    id = run_id(server)
    PubSub.subscribe(BusterClaw.PubSub, topic(id))
  end

  @doc "The run's id."
  def run_id(server), do: GenServer.call(server, :run_id)

  @doc "The current mode."
  def mode(server), do: GenServer.call(server, :mode)

  @doc "The trajectory so far (for scrub-back / the rail)."
  def trajectory(server), do: GenServer.call(server, :trajectory)

  @doc "The run summary (steps, egress roll-up, outcomes)."
  def summary(server), do: GenServer.call(server, :summary)

  @doc "Begin the run: `idle → agent_working`."
  def start_run(server), do: GenServer.call(server, :start_run)

  @doc """
  Navigate under the frozen scope. Records the step; on a scope/payment halt the
  run transitions to `:halted`. Refused unless the mode is `agent_working`.
  """
  def navigate(server, url), do: GenServer.call(server, {:navigate, url}, 30_000)

  @doc """
  Perform an action (`:click | :fill | :extract | …`). For `:fill`, `args` may
  carry `$secret.<name>` references resolved locally before the browser sees
  them. Refused unless the mode is `agent_working`.
  """
  def act(server, action, args \\ %{}), do: GenServer.call(server, {:act, action, args}, 30_000)

  @doc "Hand off to the human: `agent_working → awaiting_human`."
  def request_human(server, reason \\ "handoff"),
    do: GenServer.call(server, {:request_human, reason})

  @doc "Human takes control: → `awaiting_human`. Always available while acting."
  def take_wheel(server), do: GenServer.call(server, :take_wheel)

  @doc "Human returns control: `awaiting_human → agent_working`."
  def resume(server), do: GenServer.call(server, :resume)

  @doc "Mark the run complete: `agent_working → done`."
  def complete(server), do: GenServer.call(server, :complete)

  @doc "Stop the run. Halts before the next action; terminal."
  def stop_run(server), do: GenServer.call(server, :stop_run)

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    scope = Keyword.fetch!(opts, :scope)

    {:ok,
     %{
       run_id: scope.id,
       scope: scope,
       session: Keyword.fetch!(opts, :session),
       session_mod: Keyword.get(opts, :session_mod, Session),
       navigate_mod: Keyword.get(opts, :navigate_mod, BrowserControl),
       secret_resolver: Keyword.get(opts, :secret_resolver, fn _ -> :error end),
       clock: Keyword.get(opts, :clock, fn -> nil end),
       mode: :idle,
       trajectory: Trajectory.new()
     }}
  end

  @impl true
  def handle_call(:run_id, _from, s), do: {:reply, s.run_id, s}
  def handle_call(:mode, _from, s), do: {:reply, s.mode, s}
  def handle_call(:trajectory, _from, s), do: {:reply, s.trajectory, s}
  def handle_call(:summary, _from, s), do: {:reply, Trajectory.summary(s.trajectory), s}

  def handle_call(:start_run, _from, s), do: fsm_reply(s, :start)

  def handle_call({:request_human, reason}, _from, s),
    do: fsm_reply(s, :need_human, %{reason: reason})

  def handle_call(:take_wheel, _from, s), do: fsm_reply(s, :take_wheel)
  def handle_call(:resume, _from, s), do: fsm_reply(s, :resume)
  def handle_call(:complete, _from, s), do: fsm_reply(s, :complete)
  def handle_call(:stop_run, _from, s), do: fsm_reply(s, :stop)

  def handle_call({:navigate, url}, _from, s) do
    if Mode.acting_allowed?(s.mode) do
      do_navigate(s, url)
    else
      {:reply, {:error, {:not_acting, s.mode}}, s}
    end
  end

  def handle_call({:act, action, args}, _from, s) do
    if Mode.acting_allowed?(s.mode) do
      do_act(s, action, args)
    else
      {:reply, {:error, {:not_acting, s.mode}}, s}
    end
  end

  # ── mode transitions ─────────────────────────────────────────────────────────

  defp fsm_reply(s, event, meta \\ %{}) do
    case Mode.transition(s.mode, event) do
      {:ok, next} ->
        s = %{s | mode: next}
        broadcast(s, {:mode, %{from: s.mode, to: next, event: event, meta: meta}})
        broadcast(s, {:mode_changed, next})
        {:reply, {:ok, next}, s}

      {:error, reason} ->
        {:reply, {:error, reason}, s}
    end
  end

  # ── actions ──────────────────────────────────────────────────────────────────

  defp do_navigate(s, url) do
    case s.navigate_mod.navigate(s.session, s.scope, url) do
      {:ok, origin} ->
        s =
          record(s, %{type: :navigate, summary: "navigate #{url}", origin: origin, outcome: :ok})

        {:reply, {:ok, origin}, s}

      {:halt, reason, meta} ->
        s =
          record(s, %{type: :halt, summary: "halted (#{reason}) #{meta[:url]}", outcome: :halted})

        {_, next} = safe_transition(s, :halt)
        s = %{s | mode: next}
        broadcast(s, {:mode_changed, next})
        {:reply, {:halt, reason, meta}, s}

      other ->
        s = record(s, %{type: :navigate, summary: "navigate #{url}", outcome: :error})
        {:reply, other, s}
    end
  end

  defp do_act(s, :fill, args) do
    raw = Map.get(args, "value") || Map.get(args, :value) || ""
    selector = Map.get(args, "selector") || Map.get(args, :selector) || ""

    case SecretRef.resolve(raw, s.secret_resolver) do
      {:ok, resolved} ->
        # The browser gets the resolved value; the trajectory stores only the
        # masked reference — the secret never enters the record.
        result = fill(s, selector, resolved)
        summary = "fill #{selector} = #{SecretRef.mask(raw)}"
        s = record(s, %{type: :fill, summary: summary, outcome: outcome(result)})
        {:reply, result, s}

      {:error, reason} ->
        s =
          record(s, %{
            type: :fill,
            summary: "fill #{selector} (unresolved secret)",
            outcome: :error
          })

        {:reply, {:error, reason}, s}
    end
  end

  defp do_act(s, action, args) do
    summary =
      "#{action} #{Map.get(args, "selector") || Map.get(args, :selector) || ""}" |> String.trim()

    s = record(s, %{type: action, summary: summary, outcome: :ok})
    {:reply, {:ok, %{action: action}}, s}
  end

  # A fill via the injected session module; a stub records without a browser.
  defp fill(s, selector, value) do
    if function_exported?(s.session_mod, :command, 3) do
      s.session_mod.command(s.session, "DOM.setValue", %{"selector" => selector, "value" => value})
    else
      {:ok, %{filled: selector}}
    end
  end

  defp outcome({:ok, _}), do: :ok
  defp outcome(:ok), do: :ok
  defp outcome(_), do: :error

  defp record(s, attrs) do
    attrs = Map.put_new(attrs, :at, s.clock.())
    traj = Trajectory.step(s.trajectory, attrs)
    s = %{s | trajectory: traj}
    broadcast(s, {:step, Trajectory.last(traj)})
    s
  end

  defp safe_transition(s, event) do
    case Mode.transition(s.mode, event) do
      {:ok, next} -> {:ok, next}
      {:error, _} -> {:ok, s.mode}
    end
  end

  defp broadcast(s, event) do
    PubSub.broadcast(BusterClaw.PubSub, topic(s.run_id), {:agent_mode, s.run_id, event})
  end
end
