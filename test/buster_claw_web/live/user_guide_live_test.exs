defmodule BusterClawWeb.UserGuideLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  test "the User Guide tab renders Introduction by default with all sub-tabs", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/user-guide")

    assert html =~ "User Guide"
    # Sub-tabs present.
    assert html =~ "user-guide-tab-introduction"
    assert html =~ "user-guide-tab-setup"
    assert html =~ "user-guide-tab-daily_loop"
    # Introduction content shown by default.
    assert html =~ "Buster Claw is the environment around an AI agent"
  end

  test "selecting Setup and Daily Loop swaps the section content", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/user-guide")

    setup_html = view |> element("#user-guide-tab-setup") |> render_click()
    assert setup_html =~ "trusted-email-senders.md"

    loop_html = view |> element("#user-guide-tab-daily_loop") |> render_click()
    assert loop_html =~ "dispatch claim"
  end

  test "Home shows a button that opens the User Guide tab", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(href="/user-guide")
  end
end
