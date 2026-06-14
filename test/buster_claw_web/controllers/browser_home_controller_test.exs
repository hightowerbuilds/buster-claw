defmodule BusterClawWeb.BrowserHomeControllerTest do
  use BusterClawWeb.ConnCase, async: false

  alias BusterClaw.{Bookmarks, BrowserHistory}

  setup do
    root = Path.join(System.tmp_dir!(), "bc-bhome-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    :ok
  end

  test "homepage shows an empty state when there's no history", %{conn: conn} do
    body = conn |> get(~p"/browser/home") |> response(200)
    assert body =~ "Recent"
    assert body =~ "No recent pages yet"
  end

  test "homepage shows a Bookmarks section above Recent", %{conn: conn} do
    body = conn |> get(~p"/browser/home") |> response(200)
    assert body =~ "Bookmarks"
    assert body =~ "No bookmarks yet"
    # Bookmarks render above Recent.
    assert :binary.match(body, "Bookmarks") < :binary.match(body, "Recent")
  end

  test "homepage lists saved bookmarks with a remove form", %{conn: conn} do
    Bookmarks.add("https://saved.com", "Saved")

    body = conn |> get(~p"/browser/home") |> response(200)
    assert body =~ ~s(href="https://saved.com")
    assert body =~ ~s(action="/browser/bookmarks/remove")
    assert body =~ ~s(value="https://saved.com")
  end

  test "homepage lists recorded entries newest-first", %{conn: conn} do
    BrowserHistory.record("https://example.com", "example.com")
    BrowserHistory.record("http://127.0.0.1:4000/ws/file?path=/note.md", "/note.md")

    body = conn |> get(~p"/browser/home") |> response(200)
    assert body =~ "/note.md"
    assert body =~ ~s(href="https://example.com")
    # Newest (the workspace file) appears before the older entry.
    assert :binary.match(body, "/note.md") < :binary.match(body, "example.com")
  end

  test "POST /browser/history records a url", %{conn: conn} do
    conn = post(conn, ~p"/browser/history?url=https://recorded.com&label=Rec")
    assert conn.status == 204
    assert [%{"url" => "https://recorded.com", "label" => "Rec"}] = BrowserHistory.list()
  end
end
