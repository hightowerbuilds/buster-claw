defmodule BusterClawWeb.Status.Notify do
  @moduledoc """
  The Clock panel's Notify tab: the timer / alarm / reminder form, the upcoming
  list, and the verbs on it. Socket in, socket out, imported by `StatusLive`,
  which keeps the `handle_event` clauses — the `Status.Chat` shape.

  Timer/alarm/reminder wall-clock arithmetic lives in
  `BusterClaw.Notifications.Schedule` — pure, and extracted 08-03 so the
  next-occurrence and DST cases can be asserted without driving a mount. The
  fired-notification modal is the app-wide `NotifyLive`'s job, not this tab's.

  Split out of `StatusLive` on 10-16 (CODE_QUALITY_SWEEP Phase 9), the second of
  the two widget seams the map named.
  """
  import Phoenix.Component

  alias BusterClaw.Notifications
  alias BusterClaw.Notifications.Schedule

  def load_notifications(socket), do: assign(socket, :notifications, Notifications.upcoming())

  def notify_form, do: to_form(%{"label" => "", "minutes" => "", "at" => ""}, as: :notify)

  def select_notify_kind(socket, kind) do
    socket |> assign(:notify_kind, kind) |> assign(:notify_form, notify_form())
  end

  def create_notification(socket, params) do
    kind = Map.get(params, "kind", "timer")
    label = params |> Map.get("label", "") |> String.trim() |> Schedule.default_label(kind)

    with :ok <- if(label == "", do: {:error, :label, "add a label"}, else: :ok),
         {:ok, fire_at} <- Schedule.fire_at(kind, params) do
      attrs = %{
        "kind" => kind,
        "label" => label,
        "fire_at" => fire_at,
        "status" => "pending",
        "source" => "manual"
      }

      case Notifications.create_notification(attrs) do
        {:ok, _notification} ->
          socket |> assign(:notify_form, notify_form()) |> load_notifications()

        {:error, _changeset} ->
          assign_notify_error(socket, params, :label, "could not create #{kind}")
      end
    else
      {:error, field, message} ->
        assign_notify_error(socket, params, field, message)
    end
  end

  def dismiss_notification(socket, id) do
    notification = Enum.find(socket.assigns.notifications, &(to_string(&1.id) == id))
    if notification, do: Notifications.dismiss(notification)
    load_notifications(socket)
  end

  def snooze_notification(socket, id) do
    notification = Enum.find(socket.assigns.notifications, &(to_string(&1.id) == id))
    if notification, do: Notifications.snooze(notification, 300)
    load_notifications(socket)
  end

  defp assign_notify_error(socket, params, field, message) do
    assign(socket, :notify_form, to_form(params, as: :notify, errors: [{field, {message, []}}]))
  end
end
