defmodule BusterClawWeb.BrowserSuggestControllerTest do
  use BusterClawWeb.ConnCase, async: false

  alias BusterClaw.{Bookmarks, BrowserHistory}

  setup do
    File.rm(Bookmarks.path())
    on_exit(fn -> File.rm(Bookmarks.path()) end)
    :ok
  end

  test "merges bookmark and history matches, bookmarks first, deduped", %{conn: conn} do
    Bookmarks.add("https://elixir-lang.org", "Elixir")
    BrowserHistory.record("https://elixir-lang.org", "Elixir home")
    BrowserHistory.record("https://elixirforum.com/t/1", "Elixir Forum thread")

    hits = conn |> get(~p"/browser/suggest?q=elixir") |> json_response(200)

    assert [%{"type" => "bookmark", "url" => "https://elixir-lang.org", "label" => "Elixir"} | rest] =
             hits

    assert Enum.any?(rest, &(&1["type"] == "history" and &1["url"] =~ "elixirforum"))
    # The bookmark's url must not reappear as a history hit.
    assert Enum.count(hits, &(&1["url"] == "https://elixir-lang.org")) == 1
  end

  test "blank query returns an empty list", %{conn: conn} do
    assert conn |> get(~p"/browser/suggest?q=") |> json_response(200) == []
    assert conn |> get(~p"/browser/suggest") |> json_response(200) == []
  end

  test "caps at 8 results", %{conn: conn} do
    for i <- 1..12, do: BrowserHistory.record("https://caps.com/page#{i}", "Caps page #{i}")

    hits = conn |> get(~p"/browser/suggest?q=caps") |> json_response(200)
    assert length(hits) == 8
  end
end
