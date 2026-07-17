defmodule BusterClaw.NotificationsTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Commands, Notifications}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp notif!(attrs) do
    base = %{
      "kind" => "alarm",
      "label" => "ring",
      "fire_at" => DateTime.add(now(), 3600, :second)
    }

    {:ok, notification} = Notifications.create_notification(Map.merge(base, attrs))
    notification
  end

  describe "context" do
    test "creates, validates, and lists notifications" do
      assert {:ok, notification} =
               Notifications.create_notification(%{
                 "kind" => "timer",
                 "label" => "tea",
                 "fire_at" => DateTime.add(now(), 300, :second)
               })

      assert notification.status == "pending"
      assert notification.source == "manual"

      assert {:error, changeset} =
               Notifications.create_notification(%{
                 "kind" => "wat",
                 "label" => "x",
                 "fire_at" => now()
               })

      assert %{kind: ["is invalid"]} = errors_on(changeset)
    end

    test "upcoming returns armed rows soonest-first; next_fire_at is the earliest" do
      soon = notif!(%{"label" => "soon", "fire_at" => DateTime.add(now(), 60, :second)})
      later = notif!(%{"label" => "later", "fire_at" => DateTime.add(now(), 600, :second)})
      _dismissed = notif!(%{"label" => "gone", "status" => "dismissed"})

      assert [%{id: first}, %{id: second}] = Notifications.upcoming()
      assert first == soon.id
      assert second == later.id

      assert Notifications.next_fire_at() == soon.fire_at
    end

    test "fire_due marks due rows fired, broadcasts each, and is idempotent" do
      Notifications.subscribe()

      due = notif!(%{"label" => "now", "fire_at" => DateTime.add(now(), -10, :second)})
      _future = notif!(%{"label" => "later", "fire_at" => DateTime.add(now(), 3600, :second)})

      assert [fired] = Notifications.fire_due()
      assert fired.id == due.id
      assert fired.status == "fired"
      assert fired.fired_at

      assert_receive {:notification_fired, %{id: fired_id}}
      assert fired_id == due.id

      # A second tick finds nothing due — no double fire.
      assert [] = Notifications.fire_due()
    end

    test "snooze re-arms and dismiss retires" do
      notification = notif!(%{"fire_at" => DateTime.add(now(), -5, :second)})

      assert {:ok, snoozed} = Notifications.snooze(notification, 120)
      assert snoozed.status == "snoozed"
      assert DateTime.compare(snoozed.fire_at, now()) == :gt
      assert snoozed.fired_at == nil

      assert {:ok, dismissed} = Notifications.dismiss(snoozed)
      assert dismissed.status == "dismissed"
      # A dismissed row is no longer armed.
      assert Notifications.upcoming() == []
    end
  end

  describe "command surface" do
    test "notify_create timer resolves in_seconds to an absolute fire_at" do
      assert {:ok, notification} =
               Commands.call(
                 "notify_create",
                 %{"kind" => "timer", "label" => "tea", "in_seconds" => 600}, caller: :trusted)

      assert notification.kind == "timer"
      assert DateTime.diff(notification.fire_at, DateTime.utc_now()) in 590..600
    end

    test "notify_create alarm parses an ISO-8601 moment" do
      at = now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      assert {:ok, notification} =
               Commands.call(
                 "notify_create",
                 %{"kind" => "alarm", "label" => "meeting", "at" => at}, caller: :trusted)

      assert notification.kind == "alarm"
    end

    test "notify_create reminder fires now and a blank label is refused" do
      assert {:ok, notification} =
               Commands.call("notify_create", %{"kind" => "reminder", "label" => "note"},
                 caller: :trusted
               )

      assert notification.kind == "reminder"
      assert DateTime.compare(notification.fire_at, DateTime.add(now(), 2, :second)) != :gt

      assert {:error, :missing_label} =
               Commands.call("notify_create", %{"kind" => "reminder", "label" => "   "},
                 caller: :trusted
               )
    end

    test "notify_create timer without in_seconds errors" do
      assert {:error, :missing_in_seconds} =
               Commands.call("notify_create", %{"kind" => "timer", "label" => "x"},
                 caller: :trusted
               )
    end

    test "notify_list is safe-tier; snooze and dismiss transition status" do
      assert {:ok, created} =
               Commands.call(
                 "notify_create",
                 %{"kind" => "timer", "label" => "z", "in_seconds" => 60}, caller: :trusted)

      # :safe tier — an agent caller may read it.
      assert {:ok, [listed]} = Commands.call("notify_list", %{}, caller: :agent)
      assert listed.id == created.id

      assert {:ok, snoozed} =
               Commands.call("notify_snooze", %{"id" => created.id, "in_seconds" => 120},
                 caller: :trusted
               )

      assert snoozed.status == "snoozed"

      assert {:ok, dismissed} =
               Commands.call("notify_dismiss", %{"id" => created.id}, caller: :trusted)

      assert dismissed.status == "dismissed"
    end
  end
end
