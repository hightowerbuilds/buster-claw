defmodule BusterClawWeb.BrowseLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  # /browse is now an embedded-webview shell: the live page renders the toolbar +
  # surface + fallback, and the native webview / navigation is driven client-side
  # by the EmbeddedBrowser hook (only in the desktop app). Server-side coverage is
  # the rendered shell + the deep-link seeding the address bar.

  test "renders the browser shell with toolbar, surface, and fallback", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/browse")

    assert html =~ ~s(id="browse-shell")
    assert html =~ ~s(phx-hook="EmbeddedBrowser")
    assert html =~ "data-browser-surface"
    assert html =~ "data-browser-address"
    assert html =~ ~s(data-browser-action="back")
    assert html =~ ~s(data-browser-action="reload")
    # Fallback notice (revealed client-side outside the desktop app).
    assert html =~ "desktop app"
  end

  test "a ?url= deep link seeds the address bar and hook", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/browse?url=https://example.com")

    assert html =~ ~s(data-initial-url="https://example.com")
  end

  test "a new tab (?t=) opens blank", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/browse?t=abc123")

    assert html =~ ~s(id="browse-shell")
    refute html =~ ~s(data-initial-url="https)
  end
end
