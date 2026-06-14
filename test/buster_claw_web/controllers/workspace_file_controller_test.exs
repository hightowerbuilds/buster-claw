defmodule BusterClawWeb.WorkspaceFileControllerTest do
  use BusterClawWeb.ConnCase, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "bc-wsfile-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "renders a workspace Markdown file as HTML", %{conn: conn, root: root} do
    File.write!(Path.join(root, "note.md"), "# Hello\n\nworld")

    conn = get(conn, ~p"/ws/file", path: Path.join(root, "note.md"))

    assert response_content_type(conn, :html)
    body = response(conn, 200)
    assert body =~ "<h1>Hello</h1>"
    assert body =~ "world"
  end

  test "serves a workspace .html file as-is", %{conn: conn, root: root} do
    File.write!(Path.join(root, "page.html"), "<p id=\"x\">raw html</p>")

    body = conn |> get(~p"/ws/file", path: Path.join(root, "page.html")) |> response(200)
    assert body =~ ~s(<p id="x">raw html</p>)
  end

  test "rejects a traversal that escapes the workspace", %{conn: conn} do
    conn = get(conn, ~p"/ws/file", path: "/../../../../../../etc/hosts")
    assert conn.status == 403
  end

  test "a leading-/ path is workspace-relative (not the real filesystem root)", %{conn: conn} do
    # /etc/hosts → <workspace>/etc/hosts, which doesn't exist → 404 (never the real file).
    conn = get(conn, ~p"/ws/file", path: "/etc/hosts")
    assert conn.status == 404
  end

  test "missing path is a 400", %{conn: conn} do
    assert conn |> get(~p"/ws/file") |> response(400)
  end
end
