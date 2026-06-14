defmodule BusterClawWeb.BrowserWorkspaceControllerTest do
  use BusterClawWeb.ConnCase, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "bc-bws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "library"))
    File.write!(Path.join(root, "readme.md"), "# hi\n")
    File.write!(Path.join([root, "library", "notes.md"]), "# notes\n")
    File.write!(Path.join([root, "library", "other.txt"]), "x")

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    :ok
  end

  test "lists the workspace root with folders and files", %{conn: conn} do
    body = conn |> get(~p"/browser/workspace", q: "/") |> response(200)
    assert body =~ "library"
    assert body =~ "readme.md"
    # Folder drills back into the browser; file opens via /ws/file.
    assert body =~ ~s(href="/browser/workspace?q=#{URI.encode_www_form("/library/")}")
    assert body =~ "/ws/file?path="
  end

  test "filters by the trailing name and lists a subfolder", %{conn: conn} do
    body = conn |> get(~p"/browser/workspace", q: "/library/not") |> response(200)
    assert body =~ "notes.md"
    refute body =~ "other.txt"
    # Has a parent (..) link since we're not at root.
    assert body =~ "/browser/workspace?q=#{URI.encode_www_form("/")}"
  end

  test "/ws/file resolves a workspace-relative path", %{conn: conn} do
    body = conn |> get(~p"/ws/file", path: "/readme.md") |> response(200)
    assert body =~ "<h1>hi</h1>"
  end
end
