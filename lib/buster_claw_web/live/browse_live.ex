defmodule BusterClawWeb.BrowseLive do
  @moduledoc """
  In-app browser. In the desktop app a native child webview is overlaid on the
  surface below to render live HTTPS pages (and workspace files served by
  `/ws/file`); the `EmbeddedBrowser` JS hook keeps it glued to the surface and
  drives the `browser_*` Tauri commands. Outside the desktop app there's no
  native webview, so a fallback notice is shown.

  The toolbar (back/forward/reload + address bar) is driven entirely client-side
  by the hook, so navigation never round-trips the server. The address bar
  accepts a URL (`https://…`, scheme optional) or an absolute workspace path
  (`/…`), which the hook routes to `/ws/file`.

  ## Agent-workspace mode (BROWSER_ENGINE_ROADMAP, the UI slice)

  While an Agent Mode run is registered, the tab **visibly switches**: a hazard
  banner names the run and its mode, and a rail projects the run's trajectory
  with the human controls (take the wheel / resume / stop) and — at a Phase 5
  payment handoff — the cart card with the confirm-purchase step. The rail is
  a pure projection of `AgentMode`'s broadcasts (`subscribe_runs/0`); it adds
  no authority. The native webview shrinks around it automatically: the
  `EmbeddedBrowser` hook resizes the engine view to the surface div's box.

  Agent pages render in the run's own headful Chromium window, not this
  webview — this surface is the watchtower and the payment-confirmation desk.
  """
  use BusterClawWeb, :live_view
  import BusterClawWeb.Browser.ActivityGraph
  import BusterClawWeb.Browser.AgentWatch

  alias BusterClaw.BrowserControl.AgentMode
  alias BusterClaw.BrowserControl.AgentMode.Mode
  alias BusterClaw.BrowserControl.AgentMode.Trajectory
  alias BusterClaw.BrowserControl.Commerce
  alias BusterClaw.BrowserControl.Commerce.Cart

  @impl true
  def mount(params, session, socket) do
    # Deep link (/browse?url=…) or, when embedded as a split pane, session["url"].
    initial_url =
      case params do
        %{"url" => url} when is_binary(url) and url != "" -> url
        _ -> session["url"]
      end

    # Layout changes carry the existing native surface in the route so an open
    # browser moves between solo and joined views without reloading its page.
    surface_id =
      session["surface_id"] ||
        BusterClawWeb.PaneRoutes.browser_surface(
          if(is_map(params), do: params, else: %{}),
          "main"
        )

    if connected?(socket), do: AgentMode.subscribe_runs()

    {:ok,
     socket
     |> assign(:page_title, "Browse")
     |> assign(:initial_url, initial_url || "")
     |> assign(:surface_id, surface_id)
     |> assign(:activity_open, is_map(params) and params["activity"] == "1")
     |> assign(:activity_expanded, false)
     |> assign(:confirmation, "")
     # A SET, not a single id. It held one run_id until 08-09, and runs stay
     # registered after they end — so with two finished runs, dismissing the
     # newest revealed the older, and dismissing that one revealed the newest
     # again, because the single slot had just been overwritten. The tab stayed
     # in Agent Mode permanently for anyone who ran a second errand.
     |> assign(:agent_dismissed, MapSet.new())
     |> load_agent()}
  end

  # Any run event — new run, mode change, step — re-projects the newest run.
  @impl true
  def handle_info({:agent_mode, _run_id, _event}, socket), do: {:noreply, load_agent(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_activity", _params, socket),
    do: {:noreply, socket |> update(:activity_open, &(!&1)) |> assign(:activity_expanded, false)}

  def handle_event("close_activity", _params, socket),
    do: {:noreply, assign(socket, activity_open: false, activity_expanded: false)}

  def handle_event("expand_activity", _params, socket),
    do: {:noreply, update(socket, :activity_expanded, &(!&1))}

  def handle_event("agent_take_wheel", _params, socket),
    do: run_call(socket, &AgentMode.take_wheel/1)

  def handle_event("agent_resume", _params, socket), do: run_call(socket, &AgentMode.resume/1)
  def handle_event("agent_stop", _params, socket), do: run_call(socket, &AgentMode.stop_run/1)

  # The human's own "that's finished". `Mode` has always allowed
  # `awaiting_human → done`, for the case where the handoff WAS the last step —
  # they paid, or they decided not to, and either way the errand is over. Until
  # now nothing called it: the only human exit from a handoff was Stop, which
  # records a completed errand as halted.
  def handle_event("agent_finish", _params, socket), do: run_call(socket, &AgentMode.complete/1)

  # Clear a finished run's banner. The run stays registered (its trajectory is
  # the receipt); this is a view-level dismissal, so a NEW run — a different
  # run_id — shows up regardless of what was dismissed before.
  def handle_event("agent_dismiss", _params, socket) do
    case socket.assigns.agent_run do
      %{run_id: run_id} ->
        dismissed = MapSet.put(socket.assigns.agent_dismissed, run_id)
        {:noreply, socket |> assign(:agent_dismissed, dismissed) |> load_agent()}

      _none ->
        {:noreply, socket}
    end
  end

  # Raises the engine's own window. Deliberately not a mode change: the mirror
  # cannot show native dialogs and must not take payment details, so "go look at
  # the real thing" has to work without disturbing the run.
  def handle_event("agent_show_window", _params, socket) do
    case socket.assigns.agent_run do
      %{pid: pid} ->
        AgentMode.bring_to_front(pid)
        {:noreply, socket}

      _none ->
        {:noreply, socket}
    end
  end

  def handle_event("agent_confirm_purchase", params, socket) do
    case socket.assigns.agent_run do
      %{pid: pid} ->
        # `:human` is the whole reason this call site still exists separately
        # from `agent_run_confirm_purchase` — the receipt records which one said
        # so, and only this one is a person's own word.
        attrs = [confirmation: presence(params["confirmation"]), confirmed_by: :human]

        case Commerce.confirm_purchase(pid, attrs) do
          {:ok, _receipt} ->
            {:noreply,
             socket
             |> put_flash(:info, "Purchase confirmed.")
             |> assign(:confirmation, "")
             |> load_agent()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Confirm failed: #{inspect(reason)}")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "The browser run is no longer available.")}
    end
  end

  defp run_call(socket, fun) do
    case socket.assigns.agent_run do
      %{pid: pid} ->
        _ = safe(fn -> fun.(pid) end)
        {:noreply, load_agent(socket)}

      nil ->
        {:noreply, socket}
    end
  end

  # Project the newest registered run into assigns. Every read is exit-safe:
  # a run dying between the registry read and the call is "no run", not a crash.
  defp load_agent(socket) do
    # A live run always outranks a finished one. Runs stay registered after they
    # terminate (the trajectory is the receipt), and taking the newest
    # unconditionally meant one dead run pinned the tab in Agent Mode forever —
    # with its own Stop button hidden, because that only renders while the run
    # is still live. Prefer something actually running; fall back to the newest
    # terminal run so the outcome is visible until dismissed.
    dismissed = socket.assigns[:agent_dismissed] || MapSet.new()

    runs = AgentMode.list_runs() |> Enum.reject(&(&1.mode == :gone))
    live = Enum.find(runs, &(not Mode.terminal?(&1.mode)))
    run = live || Enum.find(runs, &(not MapSet.member?(dismissed, &1.run_id)))

    if run do
      steps = safe(fn -> run.pid |> AgentMode.trajectory() |> Trajectory.steps() end) || []
      cart = safe(fn -> AgentMode.cart(run.pid) end)

      socket
      |> assign(:agent_run, run)
      # Only a LIVE run takes the surface. A finished run keeps its banner (the
      # outcome, and the Dismiss button) but hands the browser straight back:
      # its mirror is a stream from a Chromium that has already closed, so
      # holding the surface for it meant every completed errand left the
      # operator staring at a dead frame until they found Dismiss. The agent
      # does not have to "restore" anything — ending the run is the restore.
      |> assign(:agent_live?, not Mode.terminal?(run.mode))
      |> assign(:agent_steps, Enum.reverse(steps))
      |> assign(:agent_cart, cart && Cart.summary(cart))
    else
      socket
      |> assign(:agent_run, nil)
      |> assign(:agent_live?, false)
      |> assign(:agent_steps, [])
      |> assign(:agent_cart, nil)
    end
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, _ -> nil
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} full_bleed>
      <section
        id={"browse-shell-" <> @surface_id}
        phx-hook="EmbeddedBrowser"
        data-initial-url={@initial_url}
        data-surface-id={@surface_id}
        data-agent-mirror={@agent_live? && "1"}
        data-activity-expanded={@activity_expanded && "1"}
        class="flex min-h-0 flex-1 flex-col"
      >
        <.activity_bar
          surface_id={@surface_id}
          activity_open={@activity_open}
          activity_expanded={@activity_expanded}
        />
        <%!-- Agent-workspace mode: the visible switch. Rendered OUTSIDE the
             surface div, so the native webview shrinks around it. --%>
        <.agent_banner :if={@agent_run} agent_run={@agent_run} />

        <div :if={!@activity_expanded} class="flex min-h-0 flex-1">
          <%!-- The mirror (Phase 7). While a run is live this takes the surface
               slot and the native webviews are hidden by the hook, so the browse
               tab genuinely BECOMES the agent's workspace instead of showing an
               unrelated page beside it.

               MJPEG in a plain <img>: the webview decodes natively and the
               frames never touch the LiveView channel. --%>
          <div :if={@agent_live?} class="relative min-h-0 flex-1 bg-base-300">
            <img
              src={~p"/browser/agent-view/#{@agent_run.run_id}"}
              alt="Agent browser viewport"
              class="h-full w-full object-contain"
            />
            <p class="absolute bottom-2 left-2 rounded-xs bg-base-100/80 px-2 py-1 font-mono text-[11px] text-base-content/70">
              Live view — dialogs and popups appear in the real window
            </p>
          </div>

          <%!-- The native chrome (toolbar) + content webviews are positioned over
               this surface by the hook; shrinking it makes room for the rail. --%>
          <div :if={!@agent_live?} data-browser-surface class="relative min-h-0 flex-1">
            <div
              data-browser-fallback
              class="hidden h-full place-items-center p-8 text-center text-sm text-base-content/60"
            >
              <div>
                <.icon name="hero-globe-alt" class="mx-auto size-10 text-base-content/30" />
                <p class="mt-3 font-semibold text-base-content">
                  The in-app browser runs in the Buster Claw desktop app.
                </p>
                <p class="mt-1">
                  Launch it with <code class="font-mono">./scripts/dev.sh</code> to browse here.
                </p>
              </div>
            </div>
          </div>

          <%!-- The watchable-run rail: trajectory + the payment handoff desk. --%>
          <.agent_rail
            :if={@agent_run}
            agent_run={@agent_run}
            agent_cart={@agent_cart}
            agent_steps={@agent_steps}
            confirmation={@confirmation}
          />
        </div>
        <div
          :if={@activity_open}
          class={["ic-browser-activity-panel", @activity_expanded && "expanded"]}
        >
          <.graph id={"browser-activity-" <> @surface_id} />
        </div>
      </section>
    </Layouts.app>
    """
  end
end
