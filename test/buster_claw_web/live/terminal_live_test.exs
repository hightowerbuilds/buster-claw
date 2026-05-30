defmodule BusterClawWeb.TerminalLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders the terminal host container with the xterm hook", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/terminal")

    assert html =~ "Terminal"
    assert has_element?(view, "[id^='terminal-root'][phx-hook='TerminalView']")
  end

  test "terminal is reachable from the dock nav", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(href="/terminal")
  end
end
