defmodule BusterClawWeb.WorkAreasLiveTest do
  use BusterClawWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias BusterClawWeb.WorkAreas, as: Areas

  defp saved(state), do: state |> Jason.encode!() |> Jason.decode!()

  test "overflow patches to a real area and switching back preserves child processes", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/")
    render_click(view, "restore_workbench", %{"state" => saved(Areas.new())})

    for key <- ["workspace", "notes", "calendar"],
        do: render_click(view, "select_home_tab", %{"tab" => key})

    workspace = find_live_child(view, "workbench-workspace")
    render_click(view, "workbench_terminal_new", %{})
    assert_patch(view, "/?area=area-2")
    terminal = find_live_child(view, "workbench-terminal")
    assert has_element?(view, "#workbench-pane-workspace[hidden]")
    assert has_element?(view, "#workbench-pane-terminal:not([hidden])")
    render_patch(view, "/")
    assert has_element?(view, "#workbench-pane-workspace:not([hidden])")
    assert has_element?(view, "#workbench-pane-terminal[hidden]")
    assert find_live_child(view, "workbench-workspace").pid == workspace.pid
    assert find_live_child(view, "workbench-terminal").pid == terminal.pid
    render_patch(view, "/?area=area-2")
    assert find_live_child(view, "workbench-terminal").pid == terminal.pid
  end

  test "mode changes retain grid, panel content, and saved frames", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    state = Areas.new() |> Areas.open("workspace") |> Areas.mode("overlap")
    render_click(view, "restore_workbench", %{"state" => saved(state)})
    assert has_element?(view, "#workbench-mode-grid")
    assert has_element?(view, "#workbench-mode-overlap")
    workspace = find_live_child(view, "workbench-workspace")
    assert_push_event(view, "workbench:sync", %{revision: revision, tree: grid})
    frame = %{"x" => 0.1, "y" => 0.2, "width" => 0.6, "height" => 0.6}

    render_click(view, "workbench_move", %{
      "key" => "workspace",
      "area_id" => "area-1",
      "revision" => revision,
      "frame" => frame
    })

    assert_push_event(view, "workbench:sync", %{frames: %{"workspace" => ^frame}})
    render_click(view, "workbench_mode", %{"mode" => "grid"})
    assert_push_event(view, "workbench:sync", %{mode: "grid", tree: ^grid})
    render_click(view, "workbench_mode", %{"mode" => "overlap"})

    assert_push_event(view, "workbench:sync", %{mode: "overlap", frames: %{"workspace" => ^frame}})

    assert find_live_child(view, "workbench-workspace").pid == workspace.pid
  end

  test "direct area links restore once and terminal creation waits for the saved areas", %{
    conn: conn
  } do
    state =
      Enum.reduce(["workspace", "notes", "calendar", "clock"], Areas.new(), &Areas.open(&2, &1))

    {:ok, view, _} = live(conn, "/?area=area-2")
    render_click(view, "restore_workbench", %{"state" => saved(state), "create_terminal" => true})
    assert has_element?(view, "#workbench-pane-clock:not([hidden])")
    assert has_element?(view, "#workbench-pane-terminal:not([hidden])")
    refute has_element?(view, "#workbench-pane-terminal-2")
    render_click(view, "restore_workbench", %{"state" => saved(state), "create_terminal" => true})
    refute has_element?(view, "#workbench-pane-terminal-2")
    render_click(view, "select_home_tab", %{"tab" => "notes"})
    assert_patch(view, "/")
    assert has_element?(view, "#workbench-pane-notes:not([hidden])")
  end

  test "legacy migration opens the area containing the previously active panel", %{conn: conn} do
    alias BusterClawWeb.WorkbenchState, as: Grid

    legacy =
      Enum.reduce(["workspace", "notes", "calendar", "terminal"], Grid.new(), &Grid.open(&2, &1))

    {:ok, view, _} = live(conn, "/")
    render_click(view, "restore_workbench", %{"state" => saved(legacy)})
    assert_patch(view, "/?area=area-2")
    assert has_element?(view, "#workbench-pane-terminal:not([hidden])")
    assert has_element?(view, "#workbench-pane-chat[hidden]")
  end

  test "closing an area removes only its terminal children and never closes the first area", %{
    conn: conn
  } do
    state =
      Enum.reduce(1..5, Areas.new(), fn _, state ->
        {:ok, next} = Areas.open_terminal(state)
        next
      end)

    {:ok, view, _} = live(conn, "/?area=area-2")
    render_click(view, "restore_workbench", %{"state" => saved(state)})
    first = find_live_child(view, "workbench-terminal")
    render_click(view, "workbench_close_area", %{"id" => "area-2"})
    assert_patch(view, "/")
    refute has_element?(view, "#workbench-pane-terminal-4")
    refute has_element?(view, "#workbench-pane-terminal-5")
    assert find_live_child(view, "workbench-terminal").pid == first.pid
    render_click(view, "workbench_close_area", %{"id" => "area-1"})
    assert find_live_child(view, "workbench-terminal").pid == first.pid
  end
end
