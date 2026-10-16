defmodule BusterClawWeb.WorkbenchLiveTest do
  use BusterClawWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "sidebar replaces the footer on the work area, Browser, and Settings", %{conn: conn} do
    for path <- ["/", "/browse", "/appearance", "/settings"] do
      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "#app-sidebar #home-tab-chat[href='/?panel=chat']")
      assert has_element?(view, "#app-sidebar #bc-duty-dock")
      assert has_element?(view, "#sidebar-status > #bc-duty-dock-live + #workbench-layout-picker")

      for preset <- ["columns", "rows", "grid"] do
        assert has_element?(view, "#workbench-layout-picker #workbench-layout-#{preset}")
      end

      assert has_element?(view, "#app-sidebar #bc-dock-widget [data-clock]")
      refute has_element?(view, "#app-dock")
      refute has_element?(view, "#app-sidebar a[href='/']")
    end
  end

  test "menu opens Clock alongside Chat and keeps Browser and Settings as destinations", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#workbench-pane-chat:not([hidden])")
    refute has_element?(view, ".ic-workbench-toolbar")
    refute has_element?(view, "#workbench-horizontal")
    refute has_element?(view, "#workbench-vertical")
    assert has_element?(view, "#workbench-pane-clock[hidden]")
    render_click(view, "select_home_tab", %{"tab" => "clock"})
    assert has_element?(view, "#workbench-pane-clock:not([hidden]) #home-clock")
    assert has_element?(view, "#workbench-pane-chat:not([hidden])")
    assert has_element?(view, "#workbench-browser[href='/browse']")
    assert has_element?(view, "#workbench-settings[href='/appearance']")
  end

  test "panes keep the hook's inline geometry across patches", %{conn: conn} do
    # The hook positions panes with inline custom properties the server never
    # renders. A patch that stripped them sent every open pane to the full
    # canvas — the terminal covered the chat the moment the chat streamed.
    {:ok, view, _} = live(conn, ~p"/")

    for key <- ["chat", "terminal", "clock"] do
      assert has_element?(
               view,
               "#workbench-pane-#{key}[phx-mounted*='ignore_attrs'][phx-mounted*='style']"
             )
    end

    assert has_element?(
             view,
             "#workbench-canvas[phx-mounted*='ignore_attrs'][phx-mounted*='data-stacked']"
           )
  end

  test "arranging panes restores from zoom without remounting their contents", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    render_click(view, "select_home_tab", %{"tab" => "workspace"})
    render_click(view, "select_home_tab", %{"tab" => "clock"})
    workspace = find_live_child(view, "workbench-workspace")
    view |> element("#workbench-zoom-workspace") |> render_click()
    render_click(view, "workbench_layout", %{"preset" => "grid"})
    assert_push_event(view, "workbench:sync", %{preset: "grid", zoom: nil})
    assert has_element?(view, "#workbench-pane-chat:not([hidden])")
    assert has_element?(view, "#workbench-pane-clock:not([hidden])")
    assert find_live_child(view, "workbench-workspace").pid == workspace.pid
  end

  test "workspace stays mounted while hidden, maximized, and reopened", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    render_click(view, "select_home_tab", %{"tab" => "workspace"})
    workspace = find_live_child(view, "workbench-workspace")
    view |> element("#workbench-zoom-workspace") |> render_click()
    assert has_element?(view, "#workbench-pane-chat[hidden]")
    view |> element("#workbench-zoom-workspace") |> render_click()
    assert has_element?(view, "#workbench-pane-chat:not([hidden])")
    view |> element("#workbench-close-workspace") |> render_click()
    assert has_element?(view, "#workbench-pane-workspace[hidden]")
    render_click(view, "select_home_tab", %{"tab" => "workspace"})
    assert find_live_child(view, "workbench-workspace").pid == workspace.pid
  end

  test "restores a layout after navigation and a panel deep link still opens its panel", %{
    conn: conn
  } do
    saved = %{
      "tree" => %{"axis" => "vertical", "ratio" => 0.6, "first" => "chat", "second" => "clock"},
      "active" => "clock"
    }

    {:ok, view, _} = live(conn, "/?panel=workspace")
    render_click(view, "restore_workbench", %{"state" => saved})
    assert has_element?(view, "#workbench-pane-clock:not([hidden])")
    assert has_element?(view, "#workbench-pane-workspace:not([hidden])")
    assert has_element?(view, "#workbench-pane-workspace[data-active='true']")
    render_click(view, "restore_workbench", %{"state" => %{"tree" => nil}})
    assert has_element?(view, "#workbench-pane-workspace:not([hidden])")
  end

  test "hiding the final pane offers an empty state and reopening preserves the chat host", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#workbench-close-chat") |> render_click()
    assert has_element?(view, "#workbench-empty")
    assert has_element?(view, "#workbench-pane-chat[hidden] #home-agent-chat")
    view |> element("#workbench-start-chat") |> render_click()
    refute has_element?(view, "#workbench-empty")
    assert has_element?(view, "#workbench-pane-chat:not([hidden]) #home-agent-chat")
  end

  test "the sidebar's Terminal opens up to four shells and refuses a fifth", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    assert has_element?(
             view,
             "#home-tab-terminal[data-workbench-terminal-new] [data-workbench-terminal-count]"
           )

    for _ <- 1..4, do: render_click(view, "workbench_terminal_new", %{})

    for slot <- ["terminal", "terminal-2", "terminal-3", "terminal-4"] do
      assert has_element?(view, "#workbench-pane-#{slot}:not([hidden])")
      key = BusterClawWeb.WorkbenchState.session_key(slot)
      child = find_live_child(view, "workbench-#{slot}")
      assert has_element?(child, "[phx-hook='TerminalView'][data-session-key='#{key}']")
    end

    assert has_element?(view, "#workbench-pane-terminal-4[data-active='true']")
    assert has_element?(view, "#workbench-title-terminal-3", "Terminal 3")
    # A terminal's × is the hook's (busy check, then the PTY), never a bare hide.
    assert has_element?(
             view,
             "#workbench-close-terminal-2[data-workbench-close-terminal='terminal-2']"
           )

    refute has_element?(view, "#workbench-close-terminal-2[phx-click]")
    assert has_element?(view, "#workbench-close-chat[phx-click='workbench_close']")

    render_click(view, "workbench_terminal_new", %{})
    assert_push_event(view, "workbench:limit", %{limit: 4})
    refute has_element?(view, "#workbench-pane-terminal-5")
  end

  test "closing a terminal unmounts its shell and frees the slot for the next one", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/")
    for _ <- 1..3, do: render_click(view, "workbench_terminal_new", %{})
    second = find_live_child(view, "workbench-terminal-2")

    render_click(view, "workbench_close", %{"key" => "terminal-2"})
    refute has_element?(view, "#workbench-pane-terminal-2 [phx-hook='TerminalView']")
    assert has_element?(view, "#workbench-pane-terminal-3:not([hidden])")

    render_click(view, "workbench_terminal_new", %{})

    assert has_element?(
             view,
             "#workbench-pane-terminal-2:not([hidden]) [phx-hook='TerminalView']"
           )

    assert find_live_child(view, "workbench-terminal-2").pid != second.pid
  end

  test "the terminal deep link ensures one shell rather than minting another", %{conn: conn} do
    {:ok, view, _} = live(conn, "/?panel=terminal")
    assert has_element?(view, "#workbench-pane-terminal:not([hidden])")
    refute has_element?(view, "#workbench-pane-terminal-2:not([hidden])")
    render_click(view, "select_home_tab", %{"tab" => "terminal"})
    refute has_element?(view, "#workbench-pane-terminal-2:not([hidden])")
    assert has_element?(view, "#workbench-pane-terminal[data-active='true']")
  end

  test "dragging a panel to a new spot reorders without remounting anything", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    render_click(view, "select_home_tab", %{"tab" => "workspace"})
    assert_push_event(view, "workbench:sync", %{active: "workspace"})
    render_click(view, "select_home_tab", %{"tab" => "clock"})
    assert_push_event(view, "workbench:sync", %{active: "clock"})
    workspace = find_live_child(view, "workbench-workspace")

    render_click(view, "workbench_reorder", %{"order" => ["clock", "chat", "workspace"]})
    assert_push_event(view, "workbench:sync", %{tree: tree})
    assert BusterClawWeb.WorkbenchState.leaves(tree) == ["clock", "chat", "workspace"]
    assert find_live_child(view, "workbench-workspace").pid == workspace.pid
    assert has_element?(view, "#workbench-pane-clock:not([hidden])")

    render_click(view, "workbench_reorder", %{"order" => ["clock", "chat", "nope"]})
    assert_push_event(view, "workbench:sync", %{tree: same})
    assert same == tree
  end
end
