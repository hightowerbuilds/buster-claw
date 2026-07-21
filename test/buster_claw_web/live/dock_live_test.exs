defmodule BusterClawWeb.DockLiveTest do
  # async: false — sibling suites mutate global app env; keep DB access serial.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Notifications

  test "the dock status widget mounts on non-home pages (sticky child)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/calendar")

    dock = find_live_child(view, "bc-dock")
    assert dock, "expected the sticky bc-dock child on /calendar"
    assert render(dock) =~ "data-clock"
  end

  test "an upcoming timer appears in the dock from any page", %{conn: conn} do
    {:ok, _timer} =
      Notifications.create_notification(%{
        "kind" => "timer",
        "label" => "Tea steeping",
        "fire_at" => DateTime.add(DateTime.utc_now(), 300, :second),
        "status" => "pending"
      })

    {:ok, view, _html} = live(conn, ~p"/calendar")
    dock = find_live_child(view, "bc-dock")

    html = render(dock)
    assert html =~ "Tea steeping"
    assert html =~ "data-countdown"
  end

  test "an alarm shows a wall-time slot; overflow beyond 3 collapses to +N", %{conn: conn} do
    for {label, offset} <- [{"One", 60}, {"Two", 120}, {"Three", 180}, {"Four", 240}] do
      {:ok, _} =
        Notifications.create_notification(%{
          "kind" => "alarm",
          "label" => label,
          "fire_at" => DateTime.add(DateTime.utc_now(), offset, :second),
          "status" => "pending"
        })
    end

    {:ok, view, _html} = live(conn, ~p"/")
    dock = find_live_child(view, "bc-dock")

    html = render(dock)
    assert html =~ "data-walltime"
    assert html =~ "One"
    assert html =~ "Three"
    refute html =~ "Four"
    assert html =~ "+1"
  end

  test "the dock no longer carries the theme toggle", %{conn: conn} do
    response = conn |> get(~p"/") |> html_response(200)
    refute response =~ "data-phx-theme"
  end
end
