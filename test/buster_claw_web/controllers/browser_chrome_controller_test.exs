defmodule BusterClawWeb.BrowserChromeControllerTest do
  use BusterClawWeb.ConnCase, async: true

  test "serves the native browser chrome shell", %{conn: conn} do
    conn = get(conn, ~p"/browser/chrome")

    assert response_content_type(conn, :html)
    body = response(conn, 200)
    assert body =~ ~s(id="addr")
    assert body =~ ~s(id="back")
    assert body =~ ~s(id="reload")
    assert body =~ ~s(id="home")
    # Tab strip + bookmark bar containers (rendered client-side).
    assert body =~ ~s(id="tabs")
    assert body =~ ~s(id="bookmarkbar")
    # The behavior lives in the bundled chrome app, not inline script.
    assert body =~ ~s(<script src="/assets/js/chrome.js"></script>)
    refute body =~ "window.__onContentNavigated"
  end

  test "seeds the address bar from ?url=", %{conn: conn} do
    body = conn |> get(~p"/browser/chrome", url: "https://example.com") |> response(200)
    assert body =~ ~s(value="https://example.com")
  end

  test "injects the omnibox search engine (browser_search_url setting)", %{conn: conn} do
    body = conn |> get(~p"/browser/chrome") |> response(200)
    assert body =~ ~s(data-search-url="https://duckduckgo.com/?q=")

    BusterClaw.Settings.put("browser_search_url", "https://kagi.com/search?q=")
    body = conn |> get(~p"/browser/chrome") |> response(200)
    assert body =~ ~s(data-search-url="https://kagi.com/search?q=")
  end

  test "defaults to the main surface when no ?sid= is given", %{conn: conn} do
    body = conn |> get(~p"/browser/chrome") |> response(200)
    assert body =~ ~s(data-sid="main")
  end

  test "carries the ?sid= surface id into the chrome via data-sid", %{conn: conn} do
    body = conn |> get(~p"/browser/chrome", sid: "left") |> response(200)
    assert body =~ ~s(data-sid="left")
  end

  # Parity fixtures: keep in lockstep with the `sanitize_sid` unit tests in
  # desktop/tauri/src/browser.rs. Both sides must agree on the sanitised id or
  # the chrome and Rust address different surfaces and the browser goes blank.
  test "sanitizes ?sid= exactly like the Rust sanitiser", %{conn: conn} do
    fixtures = [
      {"main", "main"},
      {"left", "left"},
      {"A1b2", "A1b2"},
      {~s(a"-<b>/3), "ab3"},
      {"we-ird_id", "weirdid"},
      {"../etc", "etc"},
      {"", "main"},
      {"!!!", "main"}
    ]

    for {input, expected} <- fixtures do
      body = conn |> get(~p"/browser/chrome", sid: input) |> response(200)
      assert body =~ ~s(data-sid="#{expected}"), "sid #{inspect(input)}"
    end
  end
end
