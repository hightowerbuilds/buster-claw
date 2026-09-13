defmodule BusterClawWeb.DutyLiveTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.{Commands, Dispatch, Orchestration, Sentinel}

  setup do
    on_exit(&Orchestration.clear_kill_switch/0)
  end

  test "the tab follows shifts started through the command surface without reloading", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/")
    bridge = find_live_child(view, "bc-duty-tab")
    assert has_element?(bridge, "#duty-tab-state[data-active=false]")

    {:ok, _} = Commands.call("shift_start", %{"unattended" => true})
    assert has_element?(bridge, "#duty-tab-state[data-active=true]")

    {:ok, _} = Orchestration.stop_shift()
    assert has_element?(bridge, "#duty-tab-state[data-active=false]")
  end

  test "an active shift survives navigation and has a dedicated page", %{conn: conn} do
    {:ok, _} = Orchestration.start_shift(unattended: true)
    {:ok, view, _} = live(conn, ~p"/terminal")
    assert has_element?(find_live_child(view, "bc-duty-tab"), "#duty-tab-state[data-active=true]")

    {:ok, duty, _} = live(conn, ~p"/duty")
    assert has_element?(duty, "#duty-page")
    assert has_element?(duty, "#duty-phone")
    assert has_element?(duty, "#duty-email")
    assert has_element?(duty, "#duty-mode", "Working on its own")
    assert has_element?(duty, "#duty-stop-limit", "a run in progress finishes")
    refute has_element?(duty, "#bc-duty-stand-down[data-claw-confirm]")
  end

  test "the duty page renders idle when off duty, with what a shift needs", %{conn: conn} do
    {:ok, duty, _} = live(conn, ~p"/duty")
    assert has_element?(duty, "#duty-idle", "Buster Claw is not watching")
    refute has_element?(duty, "#duty-page")
    assert has_element?(duty, "#duty-phone")
    assert has_element?(duty, "#duty-email")
    # Nothing is connected here, so the button gives way to the blockers.
    assert has_element?(duty, "#duty-blockers", "Before going on duty")
    refute has_element?(duty, "#bc-duty-go-on-duty")
  end

  test "standing down latches the brake and the page goes idle", %{conn: conn} do
    {:ok, _} = Orchestration.start_shift(unattended: true)
    {:ok, duty, _} = live(conn, ~p"/duty")
    duty |> element("#bc-duty-stand-down") |> render_click()
    refute Orchestration.shift_active?()
    assert Orchestration.kill_switch_engaged?()
    assert has_element?(duty, "#duty-idle")
    refute has_element?(duty, "#duty-page")
  end

  test "external stop drops an open duty page to idle", %{conn: conn} do
    {:ok, _} = Orchestration.start_shift()
    {:ok, duty, _} = live(conn, ~p"/duty")
    {:ok, _} = Orchestration.stop_shift()
    assert has_element?(duty, "#duty-idle")
  end

  test "queue progress and audit events arrive live without moving existing records", %{
    conn: conn
  } do
    {:ok, _} = Orchestration.start_shift()
    {:ok, duty, _} = live(conn, ~p"/duty")

    {:ok, item} =
      Dispatch.enqueue(%{source: "gmail", subject: "Incoming request", dedupe_key: "duty-test"})

    assert has_element?(duty, "#activity-work-#{item.id}", "Incoming request")

    {:ok, event} = Sentinel.observe(:command_invoke, "Duty test activity", %{})
    assert has_element?(duty, "#activity-audit-#{event.id}", "Duty test activity")
    assert Enum.any?(Sentinel.list_events(), &(&1.id == event.id))
    assert has_element?(duty, "#duty-journal #home-activity")
  end

  test "phone intake appears live and remains in the phone archive", %{conn: conn} do
    {:ok, _} = Orchestration.start_shift()
    {:ok, duty, _} = live(conn, ~p"/duty")

    {:ok, event} =
      BusterClaw.Telephony.record_event(%{
        direction: "inbound",
        kind: "sms",
        from_number: "+15555550101",
        to_number: "+15555550102",
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert has_element?(duty, "#activity-phone-#{event.id}", "Incoming sms")
    assert BusterClaw.Telephony.get_event(event.id)
  end

  test "queue status changes replace the existing row", %{conn: conn} do
    {:ok, _} = Orchestration.start_shift()
    {:ok, duty, _} = live(conn, ~p"/duty")
    {:ok, item} = Dispatch.enqueue(%{source: "gmail", subject: "Request", dedupe_key: "progress"})
    assert has_element?(duty, "#activity-work-#{item.id}", "queued")
    {:ok, _} = Dispatch.update_item(item, %{status: "done"})
    assert has_element?(duty, "#activity-work-#{item.id}", "done")
    refute has_element?(duty, "#activity-work-#{item.id}", "queued")
  end
end
