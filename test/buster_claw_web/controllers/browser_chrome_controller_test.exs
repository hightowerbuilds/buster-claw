defmodule BusterClawWeb.BrowserChromeControllerTest do
  use BusterClawWeb.ConnCase, async: true

  test "serves the native browser chrome toolbar", %{conn: conn} do
    conn = get(conn, ~p"/browser/chrome")

    assert response_content_type(conn, :html)
    body = response(conn, 200)
    assert body =~ ~s(id="addr")
    assert body =~ ~s(id="back")
    assert body =~ ~s(id="reload")
    assert body =~ ~s(id="home")
    assert body =~ "browser_navigate"
    # Per-tab nav callback the Rust nav handler calls on each content navigation.
    assert body =~ "window.__onContentNavigated"
    # Tab strip container (the tabs + new-tab button are rendered client-side)
    # and the tab-lifecycle commands the strip drives.
    assert body =~ ~s(id="tabs")
    assert body =~ "newtab"
    assert body =~ "browser_new_tab"
    assert body =~ "browser_switch_tab"
    assert body =~ "browser_close_tab"
    # Bookmark bar container + the loader that fetches saved bookmarks into it.
    assert body =~ ~s(id="bookmarkbar")
    assert body =~ "loadBookmarks"
  end

  test "seeds the address bar from ?url=", %{conn: conn} do
    body = conn |> get(~p"/browser/chrome", url: "https://example.com") |> response(200)
    assert body =~ ~s(value="https://example.com")
  end
end
