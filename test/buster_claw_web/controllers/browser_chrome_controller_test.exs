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
    # Address-sync hook the Rust nav handler calls on each content navigation.
    assert body =~ "window.__setAddress"
  end

  test "seeds the address bar from ?url=", %{conn: conn} do
    body = conn |> get(~p"/browser/chrome", url: "https://example.com") |> response(200)
    assert body =~ ~s(value="https://example.com")
  end
end
