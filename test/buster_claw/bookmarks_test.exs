defmodule BusterClaw.BookmarksTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Bookmarks
  alias BusterClaw.Commands.Web, as: WebCommands

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

  test "favicon_url points at the local favicon endpoint, keyed by host" do
    assert Bookmarks.favicon_url("https://example.com/page?x=1") ==
             "/browser/favicon?host=example.com"
  end

  test "entries do not persist a favicon_url (derived at render instead)" do
    Bookmarks.add("https://example.com/page?x=1", "Example")
    assert [entry] = Bookmarks.list()
    refute Map.has_key?(entry, "favicon_url")
  end

  test "favicon_url returns nil for urls with no host" do
    assert Bookmarks.favicon_url("not a url") == nil
    assert Bookmarks.favicon_url(nil) == nil
  end

  describe "folders" do
    test "stores a folder and normalizes blank/whitespace to root (nil)" do
      Bookmarks.add("https://a.com", "A", [], "  Work  ")
      Bookmarks.add("https://b.com", "B", [], "   ")
      Bookmarks.add("https://c.com", "C")

      assert [%{"folder" => "Work"}, %{"folder" => nil}, %{"folder" => nil}] =
               Enum.sort_by(Bookmarks.list(), & &1["url"])
    end

    test "filters by folder, treating blank/nil as root" do
      Bookmarks.add("https://a.com", "A", [], "Work")
      Bookmarks.add("https://b.com", "B", [], "Work")
      Bookmarks.add("https://c.com", "C")

      assert Bookmarks.list(folder: "Work") |> Enum.map(& &1["url"]) == [
               "https://b.com",
               "https://a.com"
             ]

      assert Bookmarks.list(folder: nil) |> Enum.map(& &1["url"]) == ["https://c.com"]
      assert Bookmarks.list(folder: "") |> Enum.map(& &1["url"]) == ["https://c.com"]
    end

    test "groups by folder with root first, then folders A→Z, newest-first within" do
      Bookmarks.add("https://r1.com", "R1")
      Bookmarks.add("https://z.com", "Z", [], "Zeta")
      Bookmarks.add("https://a1.com", "A1", [], "Alpha")
      Bookmarks.add("https://a2.com", "A2", [], "Alpha")
      Bookmarks.add("https://r2.com", "R2")

      grouped = Bookmarks.grouped()
      folders = Enum.map(grouped, fn {folder, _} -> folder end)
      assert folders == [nil, "Alpha", "Zeta"]

      {nil, root} = List.keyfind(grouped, nil, 0)
      assert Enum.map(root, & &1["url"]) == ["https://r2.com", "https://r1.com"]

      {"Alpha", alpha} = List.keyfind(grouped, "Alpha", 0)
      assert Enum.map(alpha, & &1["url"]) == ["https://a2.com", "https://a1.com"]
    end
  end

  describe "backward compatibility" do
    test "loads a flat (folderless) file and renders it at the root group" do
      File.write(
        Bookmarks.path(),
        Jason.encode!([
          %{"url" => "https://old.com", "label" => "Old", "tags" => ["news"]}
        ])
      )

      assert [%{"url" => "https://old.com"}] = Bookmarks.list()
      # No folder key → root group.
      assert [{nil, [%{"url" => "https://old.com"}]}] = Bookmarks.grouped()
      assert Bookmarks.list(folder: nil) |> Enum.map(& &1["url"]) == ["https://old.com"]
    end
  end

  describe "export / import" do
    test "export emits JSON that imports back without duplicates (round-trip)" do
      Bookmarks.add("https://a.com", "A", ["news"], "Work")
      Bookmarks.add("https://b.com", "B")

      before = Bookmarks.list()
      dump = Bookmarks.export()

      assert {:ok, 2} = Bookmarks.import(dump)
      assert Bookmarks.list() == before
    end

    test "import merges tags and fills a blank folder, deduping by url" do
      Bookmarks.add("https://a.com", "A", ["news"])

      assert {:ok, 1} =
               Bookmarks.import([
                 %{
                   "url" => "https://a.com",
                   "label" => "A2",
                   "tags" => ["work"],
                   "folder" => "Reading"
                 }
               ])

      assert [entry] = Bookmarks.list()
      assert entry["url"] == "https://a.com"
      assert Enum.sort(entry["tags"]) == ["news", "work"]
      assert entry["folder"] == "Reading"
      # Existing label is preserved on merge.
      assert entry["label"] == "A"
    end

    test "import preserves an existing non-blank folder" do
      Bookmarks.add("https://a.com", "A", [], "Work")

      assert {:ok, 1} =
               Bookmarks.import([%{"url" => "https://a.com", "folder" => "Reading"}])

      assert [%{"folder" => "Work"}] = Bookmarks.list()
    end

    test "import appends new urls and rejects invalid entries" do
      Bookmarks.add("https://a.com", "A")

      assert {:ok, 2} =
               Bookmarks.import([
                 %{"url" => "https://new.com", "label" => "New"},
                 %{"label" => "no url"},
                 %{"url" => ""}
               ])

      assert Bookmarks.list() |> Enum.map(& &1["url"]) |> Enum.sort() ==
               ["https://a.com", "https://new.com"]
    end

    test "import rejects non-list / invalid JSON" do
      assert Bookmarks.import("not json") == {:error, :invalid}
      assert Bookmarks.import(%{"url" => "x"}) == {:error, :invalid}
    end

    test "export_html produces a Netscape bookmark file with folders" do
      Bookmarks.add("https://a.com", "A", ["news"], "Work")
      Bookmarks.add("https://b.com", "B")

      html = Bookmarks.export_html()
      assert html =~ "<!DOCTYPE NETSCAPE-Bookmark-file-1>"
      assert html =~ ~s(<H3>Work</H3>)
      assert html =~ ~s(<A HREF="https://a.com")
      assert html =~ ~s(TAGS="news")
    end
  end

  describe "command handlers" do
    test "bookmark_add stores and reports the folder" do
      assert {:ok, %{folder: "Work", tags: ["news"]}} =
               WebCommands.bookmark_add(%{
                 "url" => "https://a.com",
                 "label" => "A",
                 "tags" => ["news"],
                 "folder" => "Work"
               })

      assert [%{"folder" => "Work"}] = Bookmarks.list()
    end

    test "bookmark_list filters by folder when given" do
      WebCommands.bookmark_add(%{"url" => "https://a.com", "folder" => "Work"})
      WebCommands.bookmark_add(%{"url" => "https://b.com"})

      assert {:ok, [%{"url" => "https://a.com"}]} =
               WebCommands.bookmark_list(%{"folder" => "Work"})

      assert {:ok, both} = WebCommands.bookmark_list(%{})
      assert length(both) == 2
    end

    test "bookmark_export / bookmark_import round-trip through the command layer" do
      WebCommands.bookmark_add(%{"url" => "https://a.com", "label" => "A", "folder" => "Work"})

      assert {:ok, %{format: "json", content: json}} = WebCommands.bookmark_export(%{})

      assert {:ok, %{format: "html", content: html}} =
               WebCommands.bookmark_export(%{"format" => "html"})

      assert html =~ "NETSCAPE-Bookmark-file"

      assert {:ok, %{imported: 1}} = WebCommands.bookmark_import(%{"json" => json})

      assert {:ok, %{imported: 2}} =
               WebCommands.bookmark_import(%{"bookmarks" => [%{"url" => "https://b.com"}]})

      assert {:error, :invalid} = WebCommands.bookmark_import(%{})
    end
  end
end
