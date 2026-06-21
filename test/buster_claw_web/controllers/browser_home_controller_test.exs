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

  test "homepage renders bookmark cards with favicon and host", %{conn: conn} do
    Bookmarks.add("https://saved.com/page", "Saved", ["news"])

    body = conn |> get(~p"/browser/home") |> response(200)
    assert body =~ ~s(class="card")
    assert body =~ ~s(class="fav")
    assert body =~ "saved.com"
    assert body =~ ~s(<span class="tag">news</span>)
  end

  test "homepage shows search + tag-filter controls when bookmarks exist", %{conn: conn} do
    Bookmarks.add("https://a.com", "A", ["news"])
    Bookmarks.add("https://b.com", "B", ["work"])

    body = conn |> get(~p"/browser/home") |> response(200)
    assert body =~ ~s(id="search")
    # A clickable filter chip per unique tag, plus the data-tags hook for JS.
    assert body =~ ~s(class="filter" data-tag="news")
    assert body =~ ~s(class="filter" data-tag="work")
    assert body =~ ~s(data-tags="news")
    assert body =~ "<script>"
  end

  test "homepage omits search controls when there are no bookmarks", %{conn: conn} do
    body = conn |> get(~p"/browser/home") |> response(200)
    refute body =~ ~s(id="search")
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
