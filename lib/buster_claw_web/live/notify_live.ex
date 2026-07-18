defmodule BusterClawWeb.NotifyLive do
  @moduledoc """
  The app-wide fired-notification modal.

  A tiny LiveView mounted `sticky: true` in the root layout, so it lives in its
  own process and persists across page navigation. It subscribes to the
  `"notifications"` topic and renders the fired modal on top of whatever page is
  showing — an alarm surfaces even when you're not on the homepage.

  It is an independent subscriber: the homepage widget (`StatusLive`) keeps its
  own subscription for its list, and the two don't interfere. Because this runs
  in a separate process, page LiveViews never receive `{:notification_fired, _}`
  and can't crash on it — which is why the modal lives here rather than in an
  `on_mount` hook shared across every view.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Notifications

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Notifications.subscribe()
    {:ok, assign(socket, :fired_queue, []), layout: false}
  end

  @impl true
  def handle_info({:notification_fired, notification}, socket) do
    if Enum.any?(socket.assigns.fired_queue, &(&1.id == notification.id)) do
      # Already showing (a duplicate broadcast) — don't re-ring.
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:fired_queue, socket.assigns.fired_queue ++ [notification])
       |> push_event("notify:play-sound", %{})}
    end
  end

  # Everything else on the topic (`{:notifications, :changed, _}`) is the widget's
  # concern, not the modal's.
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("notify_ack", %{"id" => id}, socket) do
    {:noreply, assign(socket, :fired_queue, drop(socket, id))}
  end

  def handle_event("notify_ack_snooze", %{"id" => id}, socket) do
    notification = Enum.find(socket.assigns.fired_queue, &(to_string(&1.id) == id))
    if notification, do: Notifications.snooze(notification, 300)
    {:noreply, assign(socket, :fired_queue, drop(socket, id))}
  end

  defp drop(socket, id),
    do: Enum.reject(socket.assigns.fired_queue, &(to_string(&1.id) == id))

  @impl true
  def render(assigns) do
    ~H"""
    <div id="notify-root" phx-hook="NotifySound">
      {if @fired_queue != [],
        do: BusterClawWeb.HomeWidget.notify_modal(%{notification: hd(@fired_queue)})}
    </div>
    """
  end
end
