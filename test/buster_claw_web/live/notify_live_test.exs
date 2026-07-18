defmodule BusterClawWeb.NotifyLiveTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Notifications

  defp fire_at(offset_seconds),
    do: DateTime.add(DateTime.utc_now(), offset_seconds, :second)

  test "no modal until something fires", %{conn: conn} do
    {:ok, _view, html} = live_isolated(conn, BusterClawWeb.NotifyLive)
    refute html =~ "time&#39;s up"
  end

  test "a fired notification pops the modal; Dismiss acknowledges it", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, BusterClawWeb.NotifyLive)

    {:ok, past} =
      Notifications.create_notification(%{
        "kind" => "timer",
        "label" => "Bread",
        "fire_at" => fire_at(-5),
        "status" => "pending"
      })

    # Scheduler is off in tests — drive the fire; the broadcast reaches NotifyLive.
    Notifications.fire_due()
    _ = :sys.get_state(view.pid)

    html = render(view)
    assert html =~ "time&#39;s up"
    assert html =~ "Bread"
    assert html =~ ~s(id="notify-modal-#{past.id}")
    assert html =~ ~s(phx-hook="ShaderTimer")

    render_click(view, "notify_ack", %{"id" => to_string(past.id)})
    refute render(view) =~ "time&#39;s up"
    # Acknowledge leaves the row as a "fired" record.
    assert Notifications.get_notification(past.id).status == "fired"
  end

  test "a fire pushes the play-sound event to the client", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, BusterClawWeb.NotifyLive)

    {:ok, _past} =
      Notifications.create_notification(%{
        "kind" => "timer",
        "label" => "Chime",
        "fire_at" => fire_at(-5),
        "status" => "pending"
      })

    Notifications.fire_due()

    assert_push_event(view, "notify:play-sound", %{})
  end

  test "Snooze from the modal re-arms the notification", %{conn: conn} do
    {:ok, view, _html} = live_isolated(conn, BusterClawWeb.NotifyLive)

    {:ok, past} =
      Notifications.create_notification(%{
        "kind" => "alarm",
        "label" => "Meds",
        "fire_at" => fire_at(-5),
        "status" => "pending"
      })

    Notifications.fire_due()
    _ = :sys.get_state(view.pid)
    assert render(view) =~ "time&#39;s up"

    render_click(view, "notify_ack_snooze", %{"id" => to_string(past.id)})
    refute render(view) =~ "time&#39;s up"

    updated = Notifications.get_notification(past.id)
    assert updated.status == "snoozed"
    assert DateTime.compare(updated.fire_at, DateTime.utc_now()) == :gt
  end
end
