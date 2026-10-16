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
end
