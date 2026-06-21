defmodule BusterClaw.BookmarksTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Bookmarks

  setup do
    root = Path.join(System.tmp_dir!(), "bc-bm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    :ok
  end

  test "saves newest-first and dedupes by url (moving repeats to the top)" do
    assert Bookmarks.list() == []

    Bookmarks.add("https://a.com", "A")
    Bookmarks.add("https://b.com", "B")
    Bookmarks.add("https://a.com", "A again")

    urls = Bookmarks.list() |> Enum.map(& &1["url"])
    assert urls == ["https://a.com", "https://b.com"]
    assert [%{"label" => "A again"} | _] = Bookmarks.list()
  end

  test "defaults the label to the url" do
    Bookmarks.add("https://c.com")
    assert [%{"url" => "https://c.com", "label" => "https://c.com"}] = Bookmarks.list()
  end

  test "removes by url" do
    Bookmarks.add("https://a.com", "A")
    Bookmarks.add("https://b.com", "B")
    Bookmarks.remove("https://a.com")

    assert Bookmarks.list() |> Enum.map(& &1["url"]) == ["https://b.com"]
  end

  test "ignores blank urls" do
    assert Bookmarks.add("", "x") == :ok
    assert Bookmarks.list() == []
  end

  test "stores and normalizes tags" do
    Bookmarks.add("https://a.com", "A", ["news", " Work ", "NEWS"])
    assert [%{"tags" => ["news", "work"]}] = Bookmarks.list()
  end

  test "accepts tags as comma-separated string" do
    Bookmarks.add("https://a.com", "A", "news, work ,NEWS")
    assert [%{"tags" => ["news", "work"]}] = Bookmarks.list()
  end

  test "filters by tag" do
    Bookmarks.add("https://a.com", "A", ["news"])
    Bookmarks.add("https://b.com", "B", ["work"])
    Bookmarks.add("https://c.com", "C", ["news", "work"])

    assert Bookmarks.list(tag: "news") |> Enum.map(& &1["url"]) == [
             "https://c.com",
             "https://a.com"
           ]

    assert Bookmarks.list(tag: "work") |> Enum.map(& &1["url"]) == [
             "https://c.com",
             "https://b.com"
           ]
  end

  test "backward compatible with entries that have no tags" do
    # Simulate an old bookmark file without tags
    File.write(Bookmarks.path(), Jason.encode!([%{"url" => "https://old.com", "label" => "Old"}]))
    assert [%{"url" => "https://old.com"}] = Bookmarks.list()
    assert Bookmarks.list(tag: "news") == []
  end

  test "stores a favicon url derived from the host" do
    Bookmarks.add("https://example.com/page?x=1", "Example")
    assert [%{"favicon_url" => fav}] = Bookmarks.list()
    assert fav == "https://www.google.com/s2/favicons?domain=example.com&sz=64"
  end

  test "favicon_url returns nil for urls with no host" do
    assert Bookmarks.favicon_url("not a url") == nil
    assert Bookmarks.favicon_url(nil) == nil
  end
end
