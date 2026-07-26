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
  alias BusterClaw.BrowserControl.Commerce.Cart
  alias BusterClaw.BrowserControl.Egress
  alias BusterClaw.BrowserControl.Egress.SecretRef
  alias BusterClaw.BrowserControl.Page
  alias BusterClaw.BrowserControl.Session
  alias Phoenix.PubSub

  @topic_prefix "browser_agent_mode:"
  @runs_topic "browser_agent_mode_runs"

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Start an Agent Mode run. Options:
    * `:scope` (required) — the frozen `Scope`.
    * `:session` (required) — a leased session pid (or a `:session_mod` stub).
    * `:session_mod` — a stand-in for `Session` (default `Session`), answering
      **both** `navigate/2` and `command/3`. It is threaded to `Page` (which
      needs only `command/3`) *and* to `BrowserControl.navigate/4`, whose
      post-navigation landing check reads `location.href` through it — so a stub
      that implements only the command half will fail on the first navigation.
    * `:navigate_mod` — module answering `navigate/4` (default `BrowserControl`);
      injectable so the scope gate is exercised without a browser.
    * `:secret_resolver` — `fn name -> {:ok, value} | :error end`.
    * `:on_payment` — `:halt` (default) ends the run at a payment page; `:handoff`
      (commerce) suspends into `awaiting_human` for the human to pay.
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

  @doc """
  Subscribe to the ALL-runs feed: every run's `{:agent_mode, run_id, event}` is
  mirrored here, plus `{:agent_mode, run_id, :run_started}` on registration.
  This is what the browse tab's mode switch watches — it needs to notice runs
  it didn't start.
  """
  def subscribe_runs, do: PubSub.subscribe(BusterClaw.PubSub, @runs_topic)

  @doc "The pid of a registered run by id, or nil."
  def whereis(run_id) do
    case Registry.lookup(BusterClaw.BrowserControl.RunRegistry, run_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc "All registered runs, newest first: `[%{run_id, pid, mode}]`."
  def list_runs do
    BusterClaw.BrowserControl.RunRegistry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {run_id, pid, registered_at} ->
      %{run_id: run_id, pid: pid, mode: safe_mode(pid), registered_at: registered_at}
    end)
    |> Enum.sort_by(& &1.registered_at, :desc)
  end

  defp safe_mode(pid) do
    mode(pid)
  catch
    :exit, _ -> :gone
  end

  @doc "The run's id."
  def run_id(server), do: GenServer.call(server, :run_id)

  @doc "The current mode."
  def mode(server), do: GenServer.call(server, :mode)

  @doc "The run's session (pid or test stub) — the command surface stops it with the run."
  def session(server), do: GenServer.call(server, :session)

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

  @doc """
  Attach/replace the cart the agent has built (Phase 5 commerce). Allowed only
  while `agent_working` — the cart is frozen by the payment handoff, so what the
  human is shown is exactly what a later `confirm_purchase` may bill. Recorded
  as a `:cart` step so cart-building is watchable in the trajectory.
  """
  def put_cart(server, cart), do: GenServer.call(server, {:put_cart, cart})

  @doc "The cart attached to the run (or nil)."
  def cart(server), do: GenServer.call(server, :cart)

  @doc "Hand off to the human: `agent_working → awaiting_human`."
  def request_human(server, reason \\ "handoff"),
    do: GenServer.call(server, {:request_human, reason})

  @doc "Human takes control: → `awaiting_human`. Always available while acting."
  def take_wheel(server), do: GenServer.call(server, :take_wheel)

  @doc "Human returns control: `awaiting_human → agent_working`."
  def resume(server), do: GenServer.call(server, :resume)

  @doc """
  Raise the run's real Chromium window (`Page.bringToFront`).

  The Phase 7 mirror shows the page viewport and nothing else — no tab bar, no
  basic-auth dialog, no file picker, no permission prompt, no native `<select>`
  popup, because those are OS widgets outside the compositor. And payment is
  deliberately not doable through the mirror. So the real window has to stay one
  click away; this is that click. Changes no mode and records no step — it moves
  a window, it does not touch the run.
  """
  def bring_to_front(server), do: GenServer.call(server, :bring_to_front)

  @doc """
  Capture the page the human is looking at (Phase 5: the confirmation page,
  after they paid) as a PNG under `<workspace>/browser-control/captures/`.
  Allowed only in `awaiting_human` — this exists to receipt the human's own
  checkout, not to give a working agent eyes. Recorded as a `:capture` step.
  Returns `{:ok, path}` or `{:error, reason}`; never raises (a failed capture
  must not take the run down with it).
  """
  def capture_confirmation(server), do: GenServer.call(server, :capture_confirmation, 30_000)

  @doc "Mark the run complete: `agent_working → done`."
  def complete(server), do: GenServer.call(server, :complete)

  @doc "Stop the run. Halts before the next action; terminal."
  def stop_run(server), do: GenServer.call(server, :stop_run)

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    scope = Keyword.fetch!(opts, :scope)

    # Discoverability (the browse tab's mode switch): best-effort — a duplicate
    # run id (test reuse) keeps the run working, just not registered.
    case Registry.register(
           BusterClaw.BrowserControl.RunRegistry,
           scope.id,
           System.unique_integer([:monotonic])
         ) do
      {:ok, _ref} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end

    PubSub.broadcast(BusterClaw.PubSub, @runs_topic, {:agent_mode, scope.id, :run_started})

    {:ok,
     %{
       run_id: scope.id,
       scope: scope,
       session: Keyword.fetch!(opts, :session),
       session_mod: Keyword.get(opts, :session_mod, Session),
       navigate_mod: Keyword.get(opts, :navigate_mod, BrowserControl),
       secret_resolver: Keyword.get(opts, :secret_resolver, fn _ -> :error end),
       clock: Keyword.get(opts, :clock, fn -> nil end),
       # `:halt` (default, safe): a payment page ends the run. `:handoff`
       # (commerce runs): a payment page suspends the agent into awaiting_human
       # for the human to pay. Either way the agent never touches a payment field.
       on_payment: Keyword.get(opts, :on_payment, :halt),
       # The cart the agent has built (Phase 5); frozen by the payment handoff.
       cart: nil,
       # Host of the last successful navigation — the egress policy key for
       # content-returning acts on the current page.
       current_host: nil,
       mode: :idle,
       trajectory: Trajectory.new()
     }}
  end

  @impl true
  def handle_call(:run_id, _from, s), do: {:reply, s.run_id, s}
  def handle_call(:mode, _from, s), do: {:reply, s.mode, s}
  def handle_call(:session, _from, s), do: {:reply, s.session, s}
  def handle_call(:cart, _from, s), do: {:reply, s.cart, s}

  # Cart updates only while the agent is shopping: after the handoff the cart is
  # frozen, so the total the human sees is the total the ledger can bill.
  def handle_call({:put_cart, %Cart{} = cart}, _from, s) do
    if s.mode == :agent_working do
      summary = Cart.summary(cart)
      s = %{s | cart: cart}
      s = record(s, %{type: :cart, summary: "cart #{summary.lines} = #{summary.total}"})
      {:reply, {:ok, summary}, s}
    else
      {:reply, {:error, {:cart_frozen, s.mode}}, s}
    end
  end

  def handle_call({:put_cart, _other}, _from, s), do: {:reply, {:error, :invalid_cart}, s}

  # Deliberately non-raising end to end: a capture failure after the human has
  # paid must degrade to "no receipt image", never crash the run that the
  # ledger write depends on.
  def handle_call(:capture_confirmation, _from, s) do
    cond do
      s.mode != :awaiting_human ->
        {:reply, {:error, {:not_awaiting_human, s.mode}}, s}

      not function_exported?(s.session_mod, :command, 3) ->
        {:reply, {:error, :capture_unavailable}, s}

      true ->
        case screenshot_png(s) do
          {:ok, png} ->
            path = capture_path(s.run_id)

            with :ok <- File.mkdir_p(Path.dirname(path)),
                 :ok <- File.write(path, png) do
              s =
                record(s, %{
                  type: :capture,
                  summary: "confirmation capture #{Path.basename(path)}",
                  thumbnail: path
                })

              {:reply, {:ok, path}, s}
            else
              {:error, posix} -> {:reply, {:error, {:capture_write_failed, posix}}, s}
            end

          {:error, reason} ->
            s =
              record(s, %{type: :capture, summary: "confirmation capture failed", outcome: :error})

            {:reply, {:error, reason}, s}
        end
    end
  end

  def handle_call(:trajectory, _from, s), do: {:reply, s.trajectory, s}
  def handle_call(:summary, _from, s), do: {:reply, Trajectory.summary(s.trajectory), s}

  def handle_call(:start_run, _from, s), do: fsm_reply(s, :start)

  def handle_call({:request_human, reason}, _from, s),
    do: fsm_reply(s, :need_human, %{reason: reason})

  def handle_call(:bring_to_front, _from, s) do
    {:reply, BrowserControl.reveal_window(s.session, session_mod: s.session_mod), s}
  end

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
        prev = s.mode
        s = %{s | mode: next}
        broadcast(s, {:mode, %{from: prev, to: next, event: event, meta: meta}})
        broadcast(s, {:mode_changed, next})
        {:reply, {:ok, next}, s}

      {:error, reason} ->
        {:reply, {:error, reason}, s}
    end
  end

  # ── actions ──────────────────────────────────────────────────────────────────

  defp do_navigate(s, url) do
    case s.navigate_mod.navigate(s.session, s.scope, url, session_mod: s.session_mod) do
      {:ok, origin} ->
        # The origin describes where we LANDED, not what was requested, so this
        # is what keeps Egress's per-host level honest across a redirect.
        s = %{s | current_host: origin[:host] || s.current_host}

        s =
          record(s, %{
            type: :navigate,
            summary: navigate_summary(url, origin),
            origin: origin,
            outcome: :ok
          })

        {:reply, {:ok, origin}, s}

      # A payment page in a commerce run is a HANDOFF, not a dead end (Phase 5):
      # the agent stops acting, the human completes checkout in the same headful
      # surface where popups actually work, and the run waits in awaiting_human.
      # The handoff shows the human the total and the full cart — the step and
      # the reply both carry the cart summary the ledger will later bill.
      {:halt, :payment_stop, meta} when s.on_payment == :handoff ->
        cart_summary = if s.cart, do: Cart.summary(s.cart)
        meta = Map.put(meta, :cart, cart_summary)

        s =
          record(s, %{
            type: :handoff,
            summary: "payment handoff #{meta[:url]}#{handoff_cart_line(cart_summary)}",
            outcome: :awaiting_human
          })

        {_, next} = safe_transition(s, :need_human)
        s = %{s | mode: next}
        broadcast(s, {:mode_changed, next})
        {:reply, {:handoff, :payment, meta}, s}

      {:halt, reason, meta} ->
        s =
          record(s, %{type: :halt, summary: halt_summary(reason, meta), outcome: :halted})

        {_, next} = safe_transition(s, :halt)
        s = %{s | mode: next}
        broadcast(s, {:mode_changed, next})
        {:reply, {:halt, reason, meta}, s}

      other ->
        s = record(s, %{type: :navigate, summary: "navigate #{url}", outcome: :error})
        {:reply, other, s}
    end
  end

  # A redirect is a URL the agent never asked for, so the trajectory has to say
  # so — on scrub-back, "went somewhere I was not sent" is the signature of an
  # injected or hijacked navigation, and it must not read like an ordinary one.
  defp navigate_summary(requested, %{redirected_from: _} = origin),
    do: "navigate #{requested} → #{origin[:url]} (redirect)"

  defp navigate_summary(requested, _origin), do: "navigate #{requested}"

  defp halt_summary(reason, %{redirected_from: from} = meta),
    do: "halted (#{reason}) #{meta[:url]} — redirected from #{from}"

  defp halt_summary(reason, meta), do: "halted (#{reason}) #{meta[:url]}"

  defp do_act(s, :fill, args) do
    raw = Map.get(args, "value") || Map.get(args, :value) || ""

    case SecretRef.resolve(raw, s.secret_resolver) do
      {:ok, resolved} ->
        # The browser gets the resolved value; the trajectory stores only the
        # masked reference — the secret never enters the record.
        result = page(s, fn opts -> Page.fill(s.session, args, resolved, opts) end)
        summary = "fill #{target_label(args)} = #{SecretRef.mask(raw)}"
        s = record(s, %{type: :fill, summary: summary, outcome: outcome(result)})
        {:reply, result, s}

      {:error, reason} ->
        s =
          record(s, %{
            type: :fill,
            summary: "fill #{target_label(args)} (unresolved secret)",
            outcome: :error
          })

        {:reply, {:error, reason}, s}
    end
  end

  defp do_act(s, :click, args) do
    result = page(s, fn opts -> Page.click(s.session, args, opts) end)

    s =
      record(s, %{type: :click, summary: "click #{target_label(args)}", outcome: outcome(result)})

    {:reply, result, s}
  end

  defp do_act(s, :wait, args) do
    timeout = Map.get(args, "timeout_ms")
    opts = if is_integer(timeout) and timeout > 0, do: [timeout_ms: timeout], else: []
    result = page(s, fn page_opts -> Page.wait(s.session, args, page_opts ++ opts) end)
    s = record(s, %{type: :wait, summary: "wait", outcome: outcome(result)})
    {:reply, result, s}
  end

  # Content-returning acts (Phase 3.5 made real): the raw page result becomes a
  # Snapshot, egress policy + redaction run at capture, the model gets ONLY the
  # prepared payload, and the step carries the falsifiable Report.
  defp do_act(s, action, args) when action in [:extract, :read, :find_elements] do
    case page(s, fn opts -> page_read(s.session, action, args, opts) end) do
      {:ok, {snapshot, detail}} ->
        {payload, report} = Egress.prepare(s.current_host || "unknown", snapshot)

        s =
          record(s, %{
            type: action,
            summary: String.trim("#{action} #{detail}"),
            outcome: :ok,
            egress: report
          })

        {:reply, {:ok, payload}, s}

      {:error, _reason} = error ->
        s = record(s, %{type: action, summary: to_string(action), outcome: :error})
        {:reply, error, s}
    end
  end

  defp do_act(s, action, _args) do
    s = record(s, %{type: action, summary: "#{action} (unknown action)", outcome: :error})
    {:reply, {:error, {:unknown_action, action}}, s}
  end

  # Engine acts require a CDP surface; a data-only stub session refuses loudly
  # rather than pretending the browser did something.
  defp page(s, fun) do
    if function_exported?(s.session_mod, :command, 3) do
      fun.(session_mod: s.session_mod)
    else
      {:error, :engine_unsupported}
    end
  end

  defp page_read(session, :extract, args, opts) do
    selector = Map.get(args, "selector") || Map.get(args, :selector)

    with {:ok, result} <- Page.extract(session, selector, opts) do
      {:ok, {extract_snapshot(result), selector || "page"}}
    end
  end

  defp page_read(session, :read, _args, opts) do
    with {:ok, page} <- Page.read(session, opts) do
      elements =
        for %{} = link <- List.wrap(page["links"]),
            do: %{role: "link", label: to_string(link["label"] || link["url"])}

      {:ok,
       {%Egress.Snapshot{
          title: to_string(page["title"] || ""),
          text: to_string(page["text"] || ""),
          elements: elements
        }, to_string(page["url"] || "")}}
    end
  end

  defp page_read(session, :find_elements, _args, opts) do
    with {:ok, elements} <- Page.find_elements(session, opts) do
      shaped =
        for %{} = el <- List.wrap(elements),
            do: %{role: to_string(el["tag"] || "element"), label: to_string(el["label"] || "")}

      {:ok, {%Egress.Snapshot{elements: shaped}, "#{length(shaped)} elements"}}
    end
  end

  defp extract_snapshot(%{"matches" => matches}) when is_list(matches) do
    %Egress.Snapshot{elements: Enum.map(matches, &%{label: to_string(&1["text"] || "")})}
  end

  defp extract_snapshot(%{} = page) do
    %Egress.Snapshot{title: to_string(page["title"] || ""), text: to_string(page["text"] || "")}
  end

  defp target_label(args) do
    Map.get(args, "selector") || Map.get(args, :selector) ||
      Map.get(args, "text") || Map.get(args, :text) ||
      "index #{Map.get(args, "index") || Map.get(args, :index)}"
  end

  defp outcome({:ok, _}), do: :ok
  defp outcome(:ok), do: :ok
  defp outcome(_), do: :error

  defp handoff_cart_line(nil), do: ""
  defp handoff_cart_line(summary), do: " — #{summary.lines} = #{summary.total}"

  defp screenshot_png(s) do
    case s.session_mod.command(s.session, "Page.captureScreenshot", %{}) do
      {:ok, %{"data" => b64}} when is_binary(b64) ->
        case Base.decode64(b64) do
          {:ok, png} -> {:ok, png}
          :error -> {:error, :bad_capture_data}
        end

      {:ok, other} ->
        {:error, {:bad_capture_result, other}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:capture_failed, other}}
    end
  end

  # Run ids are caller-supplied (the scope id) — collapse them to one safe path
  # component before they name a file.
  defp capture_path(run_id) do
    safe = String.replace(run_id, ~r/[^A-Za-z0-9._-]/, "-")

    BusterClaw.Library.Artifact.workspace_path([
      "browser-control",
      "captures",
      safe <> "-confirmation.png"
    ])
  end

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

  # Every event goes to the run's own topic AND the all-runs topic, so the
  # browse tab can watch without knowing run ids up front.
  defp broadcast(s, event) do
    message = {:agent_mode, s.run_id, event}
    PubSub.broadcast(BusterClaw.PubSub, topic(s.run_id), message)
    PubSub.broadcast(BusterClaw.PubSub, @runs_topic, message)
  end
end
