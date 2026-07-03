defmodule BusterClaw.BrowserHistoryTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.BrowserHistory

  test "record/list keeps every visit, newest first (no dedupe, no cap)" do
    assert BrowserHistory.list() == []

    {:ok, _} = BrowserHistory.record("https://a.com", "A")
    {:ok, _} = BrowserHistory.record("https://b.com", "B")
    {:ok, _} = BrowserHistory.record("https://a.com", "A again")

    urls = BrowserHistory.list() |> Enum.map(& &1.url)
    # Revisits are preserved, not collapsed.
    assert urls == ["https://a.com", "https://b.com", "https://a.com"]
    assert [%{title: "A again"} | _] = BrowserHistory.list()
  end

  test "recent/0 collapses revisits to one newest row per url" do
    {:ok, _} = BrowserHistory.record("https://a.com", "A")
    {:ok, _} = BrowserHistory.record("https://b.com", "B")
    {:ok, _} = BrowserHistory.record("https://a.com", "A again")

    recent = BrowserHistory.recent()
    assert Enum.map(recent, & &1.url) == ["https://a.com", "https://b.com"]
    # The retained row is the most recent visit of that URL.
    assert [%{url: "https://a.com", title: "A again"} | _] = recent
  end

  test "defaults the title to the url" do
    {:ok, _} = BrowserHistory.record("https://c.com")
    assert [%{url: "https://c.com", title: "https://c.com"}] = BrowserHistory.list()
  end

  test "ignores blank urls" do
    assert BrowserHistory.record("", "x") == :ok
    assert BrowserHistory.record(nil, "x") == :ok
    assert BrowserHistory.list() == []
  end

  test "visit_count counts revisits per url" do
    {:ok, _} = BrowserHistory.record("https://a.com", "A")
    {:ok, _} = BrowserHistory.record("https://a.com", "A")
    {:ok, _} = BrowserHistory.record("https://b.com", "B")

    assert BrowserHistory.visit_count("https://a.com") == 2
    assert BrowserHistory.visit_count("https://b.com") == 1
    assert BrowserHistory.visit_count("https://never.com") == 0
  end

  test "visit_counts ranks most-visited first" do
    {:ok, _} = BrowserHistory.record("https://a.com", "A")
    {:ok, _} = BrowserHistory.record("https://a.com", "A")
    {:ok, _} = BrowserHistory.record("https://b.com", "B")

    assert [{"https://a.com", 2}, {"https://b.com", 1}] = BrowserHistory.visit_counts()
  end

  test "search matches url and title, ranked by relevance" do
    {:ok, _} = BrowserHistory.record("https://news.example.com", "Breaking weather news")
    {:ok, _} = BrowserHistory.record("https://shopping.example.com", "Cheap shoes")

    assert {:ok, [hit | _]} = BrowserHistory.search("weather")
    assert hit.title == "Breaking weather news"

    assert {:ok, results} = BrowserHistory.search("shoes")
    assert Enum.any?(results, &(&1.url == "https://shopping.example.com"))
  end

  test "search returns empty_query for blank/no-term queries" do
    assert {:error, :empty_query} = BrowserHistory.search("")
    assert {:error, :empty_query} = BrowserHistory.search("  ?! ")
  end

  test "search tolerates FTS operator characters in user input" do
    {:ok, _} = BrowserHistory.record("https://a.com", "refund oops")
    assert {:ok, results} = BrowserHistory.search("refund AND (\"oops\")")
    assert Enum.any?(results, &(&1.title == "refund oops"))
  end

  test "grouped_by_day groups entries by calendar day" do
    {:ok, _} = BrowserHistory.record("https://a.com", "A")
    {:ok, _} = BrowserHistory.record("https://b.com", "B")

    today = Date.utc_today()
    grouped = BrowserHistory.grouped_by_day()
    assert [{^today, entries}] = grouped
    assert length(entries) == 2
  end

  test "clear removes everything" do
    {:ok, _} = BrowserHistory.record("https://a.com", "A")
    {:ok, _} = BrowserHistory.record("https://b.com", "B")

    assert BrowserHistory.clear() == 2
    assert BrowserHistory.list() == []
    # FTS index is kept in sync by the delete trigger.
    assert {:ok, []} = BrowserHistory.search("a")
  end

  test "clear_range deletes only rows within the range" do
    {:ok, old} =
      %BrowserHistory.Entry{}
      |> BrowserHistory.Entry.changeset(%{
        url: "https://old.com",
        title: "old",
        visited_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Repo.insert()

    {:ok, _new} = BrowserHistory.record("https://new.com", "new")

    deleted =
      BrowserHistory.clear_range(~U[2025-12-01 00:00:00Z], ~U[2026-01-31 00:00:00Z])

    assert deleted == 1
    refute Enum.any?(BrowserHistory.list(), &(&1.id == old.id))
    assert Enum.any?(BrowserHistory.list(), &(&1.url == "https://new.com"))
  end
end
