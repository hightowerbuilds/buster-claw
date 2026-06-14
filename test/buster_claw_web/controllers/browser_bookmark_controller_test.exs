defmodule BusterClawWeb.BrowserBookmarkControllerTest do
  use BusterClawWeb.ConnCase, async: false

  alias BusterClaw.Bookmarks

  setup do
    root = Path.join(System.tmp_dir!(), "bc-bmctl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    :ok
  end

  test "POST /browser/bookmarks saves a bookmark", %{conn: conn} do
    conn = post(conn, ~p"/browser/bookmarks?url=https://saved.com&label=Saved")
    assert conn.status == 204
    assert [%{"url" => "https://saved.com", "label" => "Saved"}] = Bookmarks.list()
  end

  test "POST /browser/bookmarks with no url is a 400", %{conn: conn} do
    conn = post(conn, ~p"/browser/bookmarks")
    assert conn.status == 400
  end

  test "POST /browser/bookmarks/remove deletes and redirects home", %{conn: conn} do
    Bookmarks.add("https://saved.com", "Saved")

    conn = post(conn, ~p"/browser/bookmarks/remove", %{"url" => "https://saved.com"})
    assert redirected_to(conn) == ~p"/browser/home"
    assert Bookmarks.list() == []
  end
end
