defmodule BusterClawWeb.BrowserSuggestController do
  @moduledoc """
  Omnibox suggestions for the embedded browser (roadmap Phase 2.2): bookmark
  matches first, then browsing history ranked by the FTS index
  (`BusterClaw.BrowserHistory.search/2`), deduped by URL, capped at 8.
  Loopback-only, single-user; no CSRF (raw scope).
  """
  use BusterClawWeb, :controller

  alias BusterClaw.{Bookmarks, BrowserHistory}

  @bookmark_cap 3
  @cap 8

  def index(conn, params) do
    q = params["q"] |> to_string() |> String.trim()

    if q == "" do
      json(conn, [])
    else
      json(conn, (bookmark_hits(q) ++ history_hits(q)) |> Enum.uniq_by(& &1.url) |> Enum.take(@cap))
    end
  end

  defp bookmark_hits(q) do
    down = String.downcase(q)

    Bookmarks.list()
    |> Enum.filter(fn e ->
      String.contains?(String.downcase(e["label"] || ""), down) or
        String.contains?(String.downcase(e["url"] || ""), down)
    end)
    |> Enum.take(@bookmark_cap)
    |> Enum.map(&%{type: "bookmark", url: &1["url"], label: &1["label"] || &1["url"]})
  end

  defp history_hits(q) do
    case BrowserHistory.search(q, limit: @cap) do
      {:ok, entries} ->
        Enum.map(entries, &%{type: "history", url: &1.url, label: &1.title || &1.url})

      _ ->
        []
    end
  end
end
