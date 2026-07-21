defmodule BusterClawWeb.DockLive do
  @moduledoc """
  The dock's right-side status widget: upcoming alarms/timers/reminders, the
  outside temperature, and a live clock.

  Mounted `sticky: true` inside the dock footer (`Layouts.app`), so it runs in
  its own process and persists across page navigation — a timer set on the
  homepage stays visible from /browse or /terminal. It is display-only: firing
  is the `Notifications.Scheduler`'s job and the ring modal is `NotifyLive`'s
  (both already app-wide); creating/dismissing lives in the homepage Notify
  widget. This just keeps what's armed in view everywhere.

  Time rendering is client-side (the `DockClock` hook ticks the clock, timer
  countdowns, and alarm/reminder wall-times from `data-*` attributes), so the
  server sends no per-second traffic. Weather reuses the TTL-cached
  `BusterClaw.Weather.current/0`, fetched async and refreshed on a slow tick.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Notifications
  alias BusterClaw.Weather

  # How many notification chips fit the dock before collapsing into "+N".
  @max_chips 3
  # Matches the Weather cache TTL posture used by the homepage sky refresh.
  @weather_refresh_ms :timer.minutes(10)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Notifications.subscribe()
      Process.send_after(self(), :weather_refresh, @weather_refresh_ms)
    end

    socket =
      socket
      |> assign(:weather, nil)
      |> load_upcoming()

    socket = if connected?(socket), do: fetch_weather(socket), else: socket

    {:ok, socket, layout: false}
  end

  @impl true
  def handle_info({:notifications, :changed, _notification}, socket),
    do: {:noreply, load_upcoming(socket)}

  def handle_info({:notification_fired, _notification}, socket),
    do: {:noreply, load_upcoming(socket)}

  def handle_info(:weather_refresh, socket) do
    Process.send_after(self(), :weather_refresh, @weather_refresh_ms)
    {:noreply, fetch_weather(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:weather, {:ok, result}, socket) do
    case result do
      {:ok, conditions} -> {:noreply, assign(socket, :weather, conditions)}
      _ -> {:noreply, socket}
    end
  end

  def handle_async(:weather, {:exit, _reason}, socket), do: {:noreply, socket}

  defp load_upcoming(socket) do
    upcoming = Notifications.upcoming(@max_chips + 9)

    socket
    |> assign(:chips, Enum.take(upcoming, @max_chips))
    |> assign(:overflow, max(length(upcoming) - @max_chips, 0))
  end

  # No location configured means nothing to show (the dock stays quiet rather
  # than prompting — location setup lives in the homepage Time & Place widget).
  defp fetch_weather(socket) do
    if Weather.location() do
      start_async(socket, :weather, fn -> Weather.current() end)
    else
      socket
    end
  end

  defp glyph("timer"), do: "⏱"
  defp glyph("alarm"), do: "⏰"
  defp glyph("reminder"), do: "🔔"
  defp glyph(_kind), do: "🔔"

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="bc-dock-widget"
      phx-hook="DockClock"
      class="flex shrink-0 items-center gap-3 font-mono text-xs text-base-content/70"
    >
      <%!-- Upcoming alarms / timers / reminders (soonest first). Timers get a
            ticking countdown; alarms/reminders show their local wall-clock time —
            both written client-side by DockClock from data-* attributes. --%>
      <span
        :for={n <- @chips}
        title={"#{String.capitalize(n.kind)} · #{n.label} — manage on Home → Notify"}
        class="flex max-w-40 items-center gap-1.5 rounded-xs border border-base-content/20 px-2 py-1"
      >
        <span aria-hidden="true">{glyph(n.kind)}</span>
        <span class="truncate text-base-content/80">{n.label}</span>
        <span
          :if={n.kind == "timer"}
          data-countdown={DateTime.to_iso8601(n.fire_at)}
          class="tabular-nums font-semibold text-primary"
        >
        </span>
        <span
          :if={n.kind != "timer"}
          data-walltime={DateTime.to_iso8601(n.fire_at)}
          class="tabular-nums font-semibold text-base-content"
        >
        </span>
      </span>
      <span :if={@overflow > 0} class="text-base-content/45" title="More on Home → Notify">
        +{@overflow}
      </span>

      <span
        :if={@weather}
        title={"#{@weather.label} in #{@weather.location} · feels #{@weather.feels_like_f}°"}
        class="text-base-content/80"
      >
        {@weather.temp_f}°
      </span>

      <span data-clock class="tabular-nums text-sm font-semibold text-base-content"></span>
    </div>
    """
  end
end
