defmodule BusterClawWeb.BrowserHistoryPageControllerTest do
  use BusterClawWeb.ConnCase, async: true

  alias BusterClaw.BrowserHistory

  test "renders day-grouped history with plain links", %{conn: conn} do
    BrowserHistory.record("https://example.com/a", "Example A")
    BrowserHistory.record("https://other.com/b", "Other B")

    body = conn |> get(~p"/browser/history") |> response(200)

    assert body =~ "Example A"
    assert body =~ ~s(href="https://other.com/b")
    assert body =~ "clear day"
    assert body =~ "Clear all"
  end

  test "?q= searches via FTS", %{conn: conn} do
    BrowserHistory.record("https://elixir-lang.org", "Elixir docs")
    BrowserHistory.record("https://rust-lang.org", "Rust docs")

    body = conn |> get(~p"/browser/history?q=elixir") |> response(200)

    assert body =~ "Elixir docs"
    refute body =~ "Rust docs"
  end

  test "clear scope=all wipes and redirects back", %{conn: conn} do
    BrowserHistory.record("https://gone.com", "Gone")

    conn2 = post(conn, ~p"/browser/history/clear", %{"scope" => "all"})
    assert redirected_to(conn2) == "/browser/history"

    body = conn |> get(~p"/browser/history") |> response(200)
    refute body =~ "Gone"
    assert body =~ "Nothing here yet"
  end

  test "clear scope=day clears only that day", %{conn: conn} do
    BrowserHistory.record("https://today.com", "Today page")
    today = Date.utc_today() |> Date.to_iso8601()

    post(conn, ~p"/browser/history/clear", %{"scope" => "day", "date" => today})

    body = conn |> get(~p"/browser/history") |> response(200)
    refute body =~ "Today page"
  end

  test "the browser homepage links to the full history", %{conn: conn} do
    body = conn |> get(~p"/browser/home") |> response(200)
    assert body =~ ~s(href="/browser/history")
  end

  test "bad clear request 400s", %{conn: conn} do
    assert conn |> post(~p"/browser/history/clear", %{"scope" => "nope"}) |> response(400)
  end
end
