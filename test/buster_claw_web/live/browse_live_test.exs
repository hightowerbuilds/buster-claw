defmodule BusterClawWeb.BrowseLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    Req.Test.verify_on_exit!()

    Req.Test.stub(BusterClaw.BrowserHTTP, fn conn ->
      case conn.request_path do
        "/page2" ->
          Req.Test.html(
            conn,
            ~s|<html><head><title>Page Two</title></head><body><p>Second page body.</p></body></html>|
          )

        _ ->
          Req.Test.html(
            conn,
            ~s|<html><head><title>Home Page</title></head><body><p>Welcome to the home page.</p><a href="/page2">Go to page two</a></body></html>|
          )
      end
    end)

    :ok
  end

  test "shows an empty state before anything is loaded", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/browse")
    assert html =~ "Nothing loaded yet"
  end

  test "a new browser tab (?t=) opens blank and independent", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/browse?t=abc123")
    assert html =~ "Nothing loaded yet"
  end

  test "auto-loads a page from a ?url= deep link", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/browse?url=https://example.com")

    assert html =~ "Home Page"
    assert html =~ "Welcome to the home page."
  end

  test "fetches and renders a page from the address bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/browse")

    html = view |> form("form", url: "https://example.com") |> render_submit()

    assert html =~ "Home Page"
    assert html =~ "Welcome to the home page."
    assert html =~ "Go to page two"
  end

  test "pushes tab metadata so the tab reflects the loaded page title", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/browse")

    view |> form("form", url: "https://example.com") |> render_submit()

    assert_push_event(view, "bc:tab_meta", %{title: "Home Page"})
  end

  test "following an in-page link navigates within the app", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/browse")
    view |> form("form", url: "https://example.com") |> render_submit()

    html = view |> element("button", "Go to page two") |> render_click()

    assert html =~ "Page Two"
    assert html =~ "Second page body."
    # Back is now available to return to the previous page.
    assert html =~ ~s|phx-click="back"|
  end

  test "back and forward walk the history", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/browse")
    view |> form("form", url: "https://example.com") |> render_submit()
    view |> element("button", "Go to page two") |> render_click()

    back_html = view |> element(~s|button[phx-click="back"]|) |> render_click()
    assert back_html =~ "Welcome to the home page."

    forward_html = view |> element(~s|button[phx-click="forward"]|) |> render_click()
    assert forward_html =~ "Second page body."
  end

  test "blocked internal addresses are refused with a safe message", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/browse")

    html = view |> form("form", url: "http://127.0.0.1") |> render_submit()

    assert html =~ "blocked for safety"
    refute html =~ "Home Page"
  end
end
