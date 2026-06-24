defmodule BusterClawWeb.GetStartedLiveTest do
  use BusterClawWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the Get Started guide under the Settings sub-tabs", %{conn: conn} do
    conn = get(conn, ~p"/get-started")
    response = html_response(conn, 200)

    # Lives in the Settings sub-tab system, with Get Started active.
    assert response =~ ~s(id="settings-tabs")
    assert response =~ ~s(id="settings-tab-get_started")

    # The onboarding content that moved off the home header widget.
    assert response =~ ~s(id="get-started")
    assert response =~ "Install Claude Code"
    assert response =~ "Chat with Buster Claw"
  end

  test "offers the quick-chat starters", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/get-started")

    assert html =~ "Quick chat"
    assert html =~ ~s(phx-click="quick_chat")
    assert html =~ "Please read through the introduction and BusterClawWorkspace"
    assert html =~ "Sentinel security layer"
    assert html =~ "overview of everything you can do across my Google Workspace"
  end
end
