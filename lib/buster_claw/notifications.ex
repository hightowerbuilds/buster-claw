defmodule BusterClaw.Notifications do
  @moduledoc """
  Notify — the agent's scheduled-moment store: timers, alarms, and reminders.

  A notification is created through the `notify_*` command surface, which every
  entry point (chat, terminal, dispatched email/voicemail) already shares, so
  BusterClaw can arm one from anywhere without per-channel wiring.

  `fire_at` is the absolute moment (a timer resolves now + duration at create
  time). `BusterClaw.Notifications.Scheduler` watches the earliest armed row and,
  when its moment arrives, flips it to `fired` and broadcasts
  `{:notification_fired, notification}` on the `"notifications"` topic — the
  homepage widget's cue to pop the modal. CRUD/status changes broadcast
  `{:notifications, :changed, notification}` so the scheduler can re-arm and the
  UI can refresh.
  """

  import Ecto.Query

  alias BusterClaw.Notifications.Notification
  alias BusterClaw.Repo

  @topic "notifications"
  # Statuses that are still waiting to fire.
  @armed ~w(pending snoozed)

  def topic, do: @topic

  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  # ---------------------------------------------------------------------------
  # CRUD (canonical shape; the command surface wraps it)
  # ---------------------------------------------------------------------------

  def list_notifications do
    Notification
    |> order_by([n], asc: n.fire_at, asc: n.id)
    |> Repo.all()
  end

  def get_notification!(id), do: Repo.get!(Notification, id)

  def get_notification(id), do: Repo.get(Notification, id)

  def create_notification(attrs) do
    %Notification{}
    |> Notification.changeset(attrs)
    |> Repo.insert()
    |> broadcast_change()
  end

  def update_notification(%Notification{} = notification, attrs) do
    notification
    |> Notification.changeset(attrs)
    |> Repo.update()
    |> broadcast_change()
  end

  def delete_notification(%Notification{} = notification) do
    notification
    |> Repo.delete()
    |> broadcast_change()
  end

  def change_notification(%Notification{} = notification \\ %Notification{}, attrs \\ %{}) do
    Notification.changeset(notification, attrs)
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc "Still-armed notifications (pending + snoozed), soonest first."
  def upcoming(limit \\ 50) do
    Notification
    |> where([n], n.status in @armed)
    |> order_by([n], asc: n.fire_at, asc: n.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "The earliest armed `fire_at`, or nil when nothing is scheduled."
  def next_fire_at do
    Notification
    |> where([n], n.status in @armed)
    |> order_by([n], asc: n.fire_at)
    |> limit(1)
    |> select([n], n.fire_at)
    |> Repo.one()
  end

  @doc "Armed notifications whose moment has arrived (`fire_at <= now`)."
  def due(now \\ now()) do
    Notification
    |> where([n], n.status in @armed and n.fire_at <= ^now)
    |> order_by([n], asc: n.fire_at, asc: n.id)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Transitions
  # ---------------------------------------------------------------------------

  @doc """
  Mark every due notification `fired` and broadcast each. Returns the fired list.
  Idempotent: a row already past `pending`/`snoozed` isn't matched by `due/1`, so
  a double tick can't fire it twice.
  """
  def fire_due(now \\ now()) do
    now
    |> due()
    |> Enum.map(&fire!/1)
  end

  defp fire!(%Notification{} = notification) do
    {:ok, fired} =
      notification
      |> Notification.changeset(%{status: "fired", fired_at: now()})
      |> Repo.update()

    broadcast({:notification_fired, fired})
    broadcast({:notifications, :changed, fired})
    fired
  end

  @doc "Re-arm a notification `seconds` from now."
  def snooze(%Notification{} = notification, seconds) when is_integer(seconds) and seconds > 0 do
    notification
    |> Notification.changeset(%{
      status: "snoozed",
      fire_at: DateTime.add(now(), seconds, :second),
      fired_at: nil
    })
    |> Repo.update()
    |> broadcast_change()
  end

  @doc "Retire a notification without firing it."
  def dismiss(%Notification{} = notification) do
    notification
    |> Notification.changeset(%{status: "dismissed"})
    |> Repo.update()
    |> broadcast_change()
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp broadcast_change({:ok, notification} = result) do
    broadcast({:notifications, :changed, notification})
    result
  end

  defp broadcast_change(result), do: result

  defp broadcast(message), do: Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, message)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
