defmodule BusterClawWeb.Status.NotifyLiveTest do
  @moduledoc """
  The Clock panel's Notify tab: timers, alarms and reminders from the form.
  """
  use BusterClawWeb.HomeCase

  describe "Notify widget" do
    alias BusterClaw.Notifications

    test "the corner widget has a Notify tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Notify"

      {:ok, view, _html} = live(conn, ~p"/")
      html = render_click(view, "select_widget_tab", %{"tab" => "notify"})
      # The kind switcher offers all three kinds; timer is the default.
      assert html =~ ~s(phx-click="notify_kind")
      assert html =~ "Alarm"
      assert html =~ "Reminder"
      assert html =~ ~s(name="notify[minutes]")
      assert html =~ "No timers set"
    end

    test "creating a timer from the form lists it and clears the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})

      html =
        view
        |> form("#notify-form", %{notify: %{label: "Tea", minutes: "5"}})
        |> render_submit()

      assert html =~ "Tea"
      assert [%{kind: "timer", label: "Tea", status: "pending"}] = Notifications.upcoming()
    end

    test "a blank label is rejected with an inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})

      html =
        view
        |> form("#notify-form", %{notify: %{label: "   ", minutes: "5"}})
        |> render_submit()

      assert html =~ "add a label"
      assert Notifications.upcoming() == []
    end

    test "switching kind swaps the form fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})

      html = render_click(view, "notify_kind", %{"kind" => "alarm"})
      assert html =~ ~s(name="notify[at]")
      refute html =~ ~s(name="notify[minutes]")

      # Reminders are wall-clock scheduled too — same time field, label required.
      html = render_click(view, "notify_kind", %{"kind" => "reminder"})
      assert html =~ ~s(name="notify[at]")
      refute html =~ ~s(name="notify[minutes]")
    end

    test "creating an alarm arms the next local occurrence of that time", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      render_click(view, "notify_kind", %{"kind" => "alarm"})

      html =
        view
        |> form("#notify-form", %{notify: %{kind: "alarm", label: "Wake", at: "07:30"}})
        |> render_submit()

      assert html =~ "Wake"
      assert [%{kind: "alarm", label: "Wake", fire_at: fire_at}] = Notifications.upcoming()

      # In the future, within the next 24h, and on a :30 wall-clock minute
      # (offsets are 15-minute granular, so the minute survives conversion).
      seconds_out = DateTime.diff(fire_at, DateTime.utc_now())
      assert seconds_out > 0
      assert seconds_out <= 86_400
      assert rem(fire_at.minute, 15) == 0
    end

    test "an alarm needs no label — blank defaults to \"Alarm\"", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      render_click(view, "notify_kind", %{"kind" => "alarm"})

      view
      |> form("#notify-form", %{notify: %{kind: "alarm", label: "  ", at: "07:30"}})
      |> render_submit()

      assert [%{kind: "alarm", label: "Alarm"}] = Notifications.upcoming()
    end

    test "a reminder still requires a label", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      render_click(view, "notify_kind", %{"kind" => "reminder"})

      html =
        view
        |> form("#notify-form", %{notify: %{kind: "reminder", label: "  "}})
        |> render_submit()

      assert html =~ "add a label"
      assert Notifications.upcoming() == []
    end

    test "an unparseable alarm time is rejected with an inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      render_click(view, "notify_kind", %{"kind" => "alarm"})

      html =
        view
        |> form("#notify-form", %{notify: %{kind: "alarm", label: "Wake", at: ""}})
        |> render_submit()

      assert html =~ "pick a time"
      assert Notifications.upcoming() == []
    end

    test "creating a reminder schedules its announcement time", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      render_click(view, "notify_kind", %{"kind" => "reminder"})

      view
      |> form("#notify-form", %{notify: %{kind: "reminder", label: "Stretch", at: "18:45"}})
      |> render_submit()

      assert [%{kind: "reminder", label: "Stretch", fire_at: fire_at}] =
               Notifications.upcoming()

      # Armed for the next local occurrence — in the future, within 24h.
      seconds_out = DateTime.diff(fire_at, DateTime.utc_now())
      assert seconds_out > 0
      assert seconds_out <= 86_400
    end

    test "a reminder without a time is rejected inline", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      render_click(view, "notify_kind", %{"kind" => "reminder"})

      html =
        view
        |> form("#notify-form", %{notify: %{kind: "reminder", label: "Stretch", at: ""}})
        |> render_submit()

      assert html =~ "pick a time"
      assert Notifications.upcoming() == []
    end

    test "the soonest notification renders a shader countdown; none when empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      empty = render_click(view, "select_widget_tab", %{"tab" => "notify"})
      refute empty =~ "ShaderTimer"

      {:ok, soonest} =
        Notifications.create_notification(%{
          "kind" => "timer",
          "label" => "Tea",
          "fire_at" => DateTime.add(DateTime.utc_now(), 120, :second),
          "status" => "pending"
        })

      {:ok, _later} =
        Notifications.create_notification(%{
          "kind" => "alarm",
          "label" => "Later",
          "fire_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "status" => "pending"
        })

      html = render(view)
      unix = DateTime.to_unix(soonest.fire_at)

      # The hero canvas is keyed by the soonest notification of the SELECTED
      # kind (timer by default) + its fire-at, driven by ShaderTimer.
      assert html =~ ~s(phx-hook="ShaderTimer")
      assert html =~ ~s(id="notify-countdown-#{soonest.id}-#{unix}")
      assert html =~ ~s(data-fire-at="#{unix}")
      assert html =~ "data-timer-canvas"
    end

    test "the countdown and list follow the selected kind", %{conn: conn} do
      {:ok, timer} =
        Notifications.create_notification(%{
          "kind" => "timer",
          "label" => "Tea",
          "fire_at" => DateTime.add(DateTime.utc_now(), 120, :second),
          "status" => "pending"
        })

      {:ok, alarm} =
        Notifications.create_notification(%{
          "kind" => "alarm",
          "label" => "Wake",
          "fire_at" => DateTime.add(DateTime.utc_now(), 3600, :second),
          "status" => "pending"
        })

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})

      # Assertions scope to the notify panel: the DOCK's status widget also shows
      # upcoming notifications page-wide, so whole-page refutes would false-fail.
      panel = fn -> view |> element("#home-notify-panel") |> render() end

      # Timer kind (default): the timer's countdown and row; the alarm is absent.
      html = panel.()
      assert html =~ ~s(id="notify-countdown-#{timer.id}-#{DateTime.to_unix(timer.fire_at)}")
      assert html =~ "Tea"
      refute html =~ "Wake"

      # Alarm kind: the hero re-keys to the alarm; the timer leaves the column.
      render_click(view, "notify_kind", %{"kind" => "alarm"})
      html = panel.()
      assert html =~ ~s(id="notify-countdown-#{alarm.id}-#{DateTime.to_unix(alarm.fire_at)}")
      assert html =~ "Wake"
      refute html =~ "Tea"

      # Reminder kind: nothing armed — no shader, honest per-kind empty state.
      render_click(view, "notify_kind", %{"kind" => "reminder"})
      html = panel.()
      refute html =~ "notify-countdown-"
      assert html =~ "No reminders set"
    end

    test "dismiss removes a notification from the widget list", %{conn: conn} do
      {:ok, notification} =
        Notifications.create_notification(%{
          "kind" => "timer",
          "label" => "Standup",
          "fire_at" => DateTime.add(DateTime.utc_now(), 600, :second),
          "status" => "pending"
        })

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      assert render(view) =~ "Standup"

      render_click(view, "notify_dismiss", %{"id" => to_string(notification.id)})

      refute render(view) =~ "Standup"
      assert Notifications.get_notification!(notification.id).status == "dismissed"
    end

    test "a fired notification leaves the widget list (modal is NotifyLive's job)",
         %{conn: conn} do
      {:ok, past} =
        Notifications.create_notification(%{
          "kind" => "alarm",
          "label" => "Ring",
          "fire_at" => DateTime.add(DateTime.utc_now(), -5, :second),
          "status" => "pending"
        })

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_widget_tab", %{"tab" => "notify"})
      # The widget filters by kind — an alarm only shows on the Alarm tab.
      render_click(view, "notify_kind", %{"kind" => "alarm"})
      assert render(view) =~ "Ring"

      # Scheduler is off in tests; drive the fire directly. Its broadcast reaches
      # the view, which drops the now-fired item from "upcoming". The modal is
      # rendered by the separate NotifyLive process, not here.
      Notifications.fire_due()
      assert Notifications.get_notification!(past.id).status == "fired"

      _ = :sys.get_state(view.pid)
      html = render(view)
      refute html =~ "Ring"
      refute html =~ "time&#39;s up"
    end
  end
end
