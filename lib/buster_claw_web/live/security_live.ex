defmodule BusterClawWeb.SecurityLive do
  @moduledoc """
  Security alert center: the live, durable feed of Sentinel audit events
  (refused restricted commands, consequential command invocations, and — as the
  spine is wired further — outbound sends and untrusted ingests). Subscribes to
  the `"security_alerts"` topic so events appear in real time.

  Also the home of **About** since 10-17 — version and build, the setup re-run,
  and the iMessage access probe — because this is the tab you visit when
  something is wrong, and the Configuration rail it sat on is gone.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.BuildInfo
  alias BusterClaw.Sentinel
  alias BusterClaw.Setup

  @keep 100

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, Sentinel.topic())

    {:ok,
     socket
     |> assign(:page_title, "Security")
     # --- about ---
     # Both are constant for the life of the VM, so they are read once at mount
     # rather than on every render. See `BusterClaw.BuildInfo` for why they are
     # derived rather than stored. About lived on the Configuration rail until
     # 10-17; it is the foot of this page now — the tab you visit when
     # something is wrong is the right place for "which build is this".
     |> assign(:build_version, BuildInfo.version())
     |> assign(:build_architecture, BuildInfo.architecture_label())
     |> assign(:status, Setup.status())
     |> assign(:messages_probe, nil)
     |> load()}
  end

  @impl true
  def handle_info({:security_event, event}, socket) do
    {:noreply,
     socket
     |> stream_insert(:events, event, at: 0, limit: @keep)
     |> update(:events_count, &min(&1 + 1, @keep))
     |> assign(:unacknowledged, Sentinel.count_unacknowledged())}
  end

  # Phase 0 pending-action notices share this topic; ignore everything else.
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("acknowledge", %{"id" => id}, socket) do
    _ = Sentinel.acknowledge(id)
    {:noreply, load(socket)}
  end

  def handle_event("acknowledge_all", _params, socket) do
    {:ok, _count} = Sentinel.acknowledge_all()
    {:noreply, load(socket)}
  end

  # --- About -----------------------------------------------------------------

  def handle_event("rerun_setup", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/setup")}
  end

  # A second click while the first probe is still running is ignored.
  def handle_event("probe_messages", _params, %{assigns: %{messages_probe: :checking}} = socket),
    do: {:noreply, socket}

  def handle_event("probe_messages", _params, socket) do
    {:noreply,
     socket
     |> assign(:messages_probe, :checking)
     |> start_async(:messages_probe, fn -> BusterClaw.Messages.probe() end)}
  end

  @impl true
  def handle_async(:messages_probe, {:ok, result}, socket),
    do: {:noreply, assign(socket, :messages_probe, result)}

  def handle_async(:messages_probe, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :messages_probe, {:error, :unavailable})}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket}>
      <section class="space-y-6">
        <BusterClawWeb.SettingsTabs.tabs active={:security} />

        <div class="flex items-center gap-3">
          <span class={[
            "rounded-full px-3 py-1 text-sm font-semibold",
            if(@unacknowledged > 0,
              do: "bg-warning/15 text-warning",
              else: "bg-success/15 text-success"
            )
          ]}>
            {@unacknowledged} unacknowledged
          </span>
          <button
            :if={@unacknowledged > 0}
            type="button"
            phx-click="acknowledge_all"
            class="rounded border border-base-300 px-3 py-2 text-sm hover:bg-base-200"
          >
            Acknowledge all
          </button>
        </div>

        <section class="rounded-lg border border-base-300 bg-base-100">
          <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
            {@events_count} recent events
          </div>

          <div id="security-events" phx-update="stream" class="divide-y divide-base-300">
            <div
              :for={{dom_id, event} <- @streams.events}
              id={dom_id}
              class={[
                "flex items-start gap-4 px-4 py-4",
                is_nil(event.acknowledged_at) || "opacity-60"
              ]}
            >
              <span class={[
                "mt-0.5 shrink-0 rounded px-2 py-1 text-xs font-bold uppercase tracking-wide",
                severity_class(event.severity)
              ]}>
                {event.severity}
              </span>

              <div class="min-w-0 flex-1">
                <p class="text-sm font-medium">{event.message}</p>
                <p class="mt-1 font-mono text-xs text-base-content/60">
                  {event.category}
                  <span :if={event.caller}>· caller: {event.caller}</span>
                  · {format_dt(event.inserted_at)}
                </p>
              </div>

              <button
                :if={is_nil(event.acknowledged_at)}
                type="button"
                phx-click="acknowledge"
                phx-value-id={event.id}
                class="shrink-0 rounded border border-base-300 px-3 py-1.5 text-xs hover:bg-base-200"
              >
                Ack
              </button>
            </div>
          </div>

          <div
            :if={@events_count == 0}
            class="px-4 py-10 text-center text-sm text-base-content/60"
          >
            No security events recorded yet.
          </div>
        </section>

        <section id="about" class="ic-panel space-y-4 p-6">
          <h2 class="ic-eyebrow">About</h2>
          <dl class="grid gap-3 sm:grid-cols-2">
            <div>
              <dt class="ic-eyebrow">Version</dt>
              <dd class="mt-1 font-mono text-lg">{@build_version}</dd>
            </div>
            <div>
              <dt class="ic-eyebrow">Build</dt>
              <dd class="mt-1 font-mono text-lg">{@build_architecture}</dd>
            </div>
          </dl>
          <p class="text-sm text-base-content/60">
            Buster Claw ships one build per processor architecture — never a universal
            binary. Quote both lines when reporting a problem.
          </p>
          <div class="flex flex-wrap items-center justify-between gap-3 border-t-2 border-base-content/15 pt-4">
            <span class="text-sm text-base-content/70">
              Setup: <span class="font-mono">{@status.completed} of {@status.total}</span>
              steps complete.
            </span>
            <button
              type="button"
              phx-click="rerun_setup"
              class="rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:bg-base-200"
            >
              {if @status.complete?, do: "Re-run setup wizard", else: "Finish setup"}
            </button>
          </div>
        </section>
        <BusterClawWeb.MessagesProbe.panel result={@messages_probe} />
      </section>
    </Layouts.app>
    """
  end

  defp load(socket) do
    events = Sentinel.list_events(limit: @keep)

    socket
    |> stream(:events, events, reset: true, limit: @keep)
    |> assign(:events_count, length(events))
    |> assign(:unacknowledged, Sentinel.count_unacknowledged())
  end

  defp severity_class("critical"), do: "bg-error/15 text-error"
  defp severity_class("warning"), do: "bg-warning/15 text-warning"
  defp severity_class("notice"), do: "bg-info/15 text-info"
  defp severity_class(_), do: "bg-base-200 text-base-content/70"

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_dt(_), do: ""
end
