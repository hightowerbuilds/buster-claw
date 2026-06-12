defmodule BusterClawWeb.UserGuideLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  test "the Manual tab renders Introduction by default with all sub-tabs", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/manual")

    assert html =~ "Manual"
    # Sub-tabs present.
    assert html =~ "user-guide-tab-introduction"
    assert html =~ "user-guide-tab-setup"
    assert html =~ "user-guide-tab-daily_loop"
    # Introduction content shown by default.
    assert html =~ "Buster Claw is the environment around an AI agent"
  end

  test "selecting Setup and Daily Loop swaps the section content", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/manual")

    setup_html = view |> element("#user-guide-tab-setup") |> render_click()
    assert setup_html =~ "trusted-email-senders.md"

    loop_html = view |> element("#user-guide-tab-daily_loop") |> render_click()
    assert loop_html =~ "dispatch claim"
  end

  test "the footer dock links to the Manual", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(href="/manual")
  end
end
