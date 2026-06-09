defmodule BusterClawWeb.TerminalWorkspaceHookTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.TerminalWorkspace

  setup do
    TerminalWorkspace.drain_pending()
    :ok
  end

  test "pushes live terminal-open requests to the browser", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert {:ok, request} =
             TerminalWorkspace.open(%{
               "role_key" => "mail-triage",
               "label" => "Mail Triage",
               "purpose" => "Handle incoming email"
             })

    id = request.id
    session_key = request.session_key
    path = request.path

    assert_push_event(view, "bc:open_terminal", %{
      id: ^id,
      role_key: "mail-triage",
      label: "Mail Triage",
      purpose: "Handle incoming email",
      session_key: ^session_key,
      startup_profile: "mailman",
      path: ^path,
      activate: true
    })
  end

  test "drains pending terminal-open requests when a top-level LiveView connects", %{conn: conn} do
    assert {:ok, request} =
             TerminalWorkspace.open(%{
               "role_key" => "dispatcher",
               "label" => "Dispatcher"
             })

    {:ok, view, _html} = live(conn, ~p"/")

    id = request.id
    session_key = request.session_key
    path = request.path

    assert_push_event(view, "bc:open_terminal", %{
      id: ^id,
      role_key: "dispatcher",
      label: "Dispatcher",
      session_key: ^session_key,
      path: ^path,
      activate: true
    })

    assert [] = TerminalWorkspace.drain_pending()
  end
end
