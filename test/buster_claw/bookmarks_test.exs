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
end
