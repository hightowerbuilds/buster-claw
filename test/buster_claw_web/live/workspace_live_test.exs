defmodule BusterClawWeb.WorkspaceLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    root =
      Path.join(System.tmp_dir!(), "buster-claw-ws-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "library"))
    File.write!(Path.join(root, "readme.md"), "# workspace\n")

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    prev_lib = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :library_root, Path.join(root, "library"))

    on_exit(fn ->
      if prev_ws, do: Application.put_env(:buster_claw, :workspace_root, prev_ws)
      if prev_lib, do: Application.put_env(:buster_claw, :library_root, prev_lib)
      File.rm_rf(root)
    end)

    %{root: root, root_abs: Path.expand(root)}
  end

  test "renders the workspace tree with manage controls", %{conn: conn, root_abs: root_abs} do
    {:ok, _view, html} = live(conn, ~p"/workspace")
    assert html =~ "Workspace"
    assert html =~ root_abs
    assert html =~ "readme.md"
    assert html =~ "library"
    assert html =~ "+ Folder"
  end

  test "selecting a file previews its contents", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element(~s|#workspace button[phx-click="select"]|)
    |> render_click()

    # .md files render as a sanitized blog-style HTML preview (not raw source).
    html = render(view)
    assert html =~ "md-prose"
    assert html =~ "<h1>workspace</h1>"
  end

  test "create a folder then delete it via the tree", %{
    conn: conn,
    root: root,
    root_abs: root_abs
  } do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element(~s|#workspace button[phx-value-kind="dir"][phx-value-parent="#{root_abs}"]|)
    |> render_click()

    view
    |> element(~s|#workspace form[phx-submit="submit_create"]|)
    |> render_submit(%{"name" => "fresh"})

    assert File.dir?(Path.join(root, "fresh"))

    # Deleting is a two-step inline confirm (no native window.confirm — it
    # silently no-ops in the webview shell).
    view
    |> element(
      ~s|#workspace button[phx-click="start_delete"][phx-value-path="#{Path.join(root_abs, "fresh")}"]|
    )
    |> render_click()

    view
    |> element(
      ~s|#workspace button[phx-click="delete"][phx-value-path="#{Path.join(root_abs, "fresh")}"]|
    )
    |> render_click()

    refute File.exists?(Path.join(root, "fresh"))
  end

  test "deletes an existing non-empty folder via the tree", %{
    conn: conn,
    root: root,
    root_abs: root_abs
  } do
    File.write!(Path.join([root, "library", "note.md"]), "# note\n")
    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element(
      ~s|#workspace button[phx-click="start_delete"][phx-value-path="#{Path.join(root_abs, "library")}"]|
    )
    |> render_click()

    view
    |> element(
      ~s|#workspace button[phx-click="delete"][phx-value-path="#{Path.join(root_abs, "library")}"]|
    )
    |> render_click()

    refute File.exists?(Path.join(root, "library"))
  end

  test "navigates up to the parent directory and offers to set it as workspace", %{
    conn: conn,
    root: root
  } do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    html = view |> element("button", "Up") |> render_click()

    # The parent listing now includes the old workspace folder as a child,
    # and since we're above the workspace we can re-root or set a new one.
    assert html =~ Path.basename(Path.expand(root))
    assert html =~ "Set as workspace"
    assert html =~ "Go to workspace"
  end
end
