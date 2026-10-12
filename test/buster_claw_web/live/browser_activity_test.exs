defmodule BusterClawWeb.BrowserActivityTest do
  use BusterClawWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias BusterClaw.Browser.Activity

  test "graph can be opened and closed without replacing the browser surface", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/browse")
    assert has_element?(view, "[data-browser-surface]")
    refute has_element?(view, "#browser-activity-main")

    view |> element("#browser-activity-toggle-main") |> render_click()
    assert has_element?(view, "#browser-activity-main[phx-update=ignore]")
    assert has_element?(view, "#browser-activity-main-source")
    assert has_element?(view, "#browser-activity-main-fit")
    assert has_element?(view, "[data-browser-surface]")

    view |> element("#browser-activity-expand-main") |> render_click()
    assert has_element?(view, "#browse-shell-main[data-activity-expanded='1']")
    refute has_element?(view, "[data-browser-surface]")
    assert has_element?(view, "#browser-activity-main")
    view |> element("#browser-activity-expand-main") |> render_click()
    assert has_element?(view, "[data-browser-surface]")

    view |> element("#browser-activity-toggle-main") |> render_click()
    refute has_element?(view, "#browser-activity-main")
    assert has_element?(view, "[data-browser-surface]")
    render_hook(view, "toggle_activity", %{})
    assert has_element?(view, "#browser-activity-main")
    render_hook(view, "toggle_activity", %{})
    refute has_element?(view, "#browser-activity-main")

    view |> element("#browser-activity-toggle-main") |> render_click()
    view |> element("#browser-activity-main-close") |> render_click()
    refute has_element?(view, "#browser-activity-main")
    assert has_element?(view, "[data-browser-surface]")

    view |> element("#browser-activity-toggle-main") |> render_click()
    view |> element("#browser-activity-expand-main") |> render_click()
    view |> element("#browser-activity-main-close") |> render_click()
    refute has_element?(view, "#browser-activity-main")
    assert has_element?(view, "[data-browser-surface]")
    refute has_element?(view, "#browse-shell-main[data-activity-expanded='1']")
  end

  test "browser chrome can deep-link to the graph", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/browse?activity=1")
    assert has_element?(view, "#browser-activity-main[data-endpoint='/browser/activity/events']")

    page = conn |> get(~p"/browser/chrome") |> html_response(200) |> LazyHTML.from_document()
    assert LazyHTML.query(page, "#activity") |> Enum.count() == 1
  end

  test "read-only feed returns bounded sanitized records and honors run selection", %{conn: conn} do
    {:ok, _} = Activity.record(%{source: "shared", action: "read", outcome: "ok"})

    {:ok, event} =
      Activity.record(%{
        source: "agent",
        run_id: "run-feed",
        action: "navigate",
        outcome: "ok",
        url: "https://example.com/page?secret=yes"
      })

    conn = get(conn, ~p"/browser/activity/events?run_id=run-feed")
    body = json_response(conn, 200)
    assert [%{"id" => id, "url" => "https://example.com/page"}] = body["events"]
    assert id == event.id
    assert body["runs"] == ["run-feed"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end
end
