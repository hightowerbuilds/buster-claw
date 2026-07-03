defmodule BusterClawWeb.HistoryLiveTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.BrowserHistory

  setup do
    BusterClaw.Settings.put("onboarding_completed_at", DateTime.utc_now() |> DateTime.to_iso8601())
    :ok
  end

  test "renders day-grouped history with links back into the browser", %{conn: conn} do
    BrowserHistory.record("https://example.com/a", "Example A")
    BrowserHistory.record("https://other.com/b", "Other B")

    {:ok, _view, html} = live(conn, ~p"/history")

    assert html =~ "Example A"
    assert html =~ "Other B"
    assert html =~ "/browse?url="
  end

  test "search narrows the list", %{conn: conn} do
    BrowserHistory.record("https://elixir-lang.org", "Elixir docs")
    BrowserHistory.record("https://rust-lang.org", "Rust docs")

    {:ok, view, _html} = live(conn, ~p"/history")
    html = render_change(view, "search", %{"q" => "elixir"})

    assert html =~ "Elixir docs"
    refute html =~ "Rust docs"
  end

  test "clear_all empties the page", %{conn: conn} do
    BrowserHistory.record("https://gone.com", "Gone")

    {:ok, view, _html} = live(conn, ~p"/history")
    html = render_click(view, "clear_all")

    refute html =~ "Gone"
    assert html =~ "Nothing here yet"
  end
end
