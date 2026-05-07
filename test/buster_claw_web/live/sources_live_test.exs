defmodule BusterClawWeb.SourcesLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Sources

  test "renders configured sources", %{conn: conn} do
    {:ok, _source} =
      Sources.create_source(%{
        url: "https://example.com/feed.xml",
        type: "rss",
        name: "Example Feed",
        tags: %{"items" => ["ai", "news"]}
      })

    {:ok, _view, html} = live(conn, ~p"/sources")

    assert html =~ "Sources"
    assert html =~ "Example Feed"
    assert html =~ "https://example.com/feed.xml"
    assert html =~ "ai"
  end

  test "adds and deletes a source from the UI", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/sources")
    assert html =~ "No sources configured yet"

    html =
      view
      |> form("form", %{
        source: %{
          url: "https://example.com/story",
          name: "Story",
          type: "article",
          tags_text: "ai, research"
        }
      })
      |> render_submit()

    assert html =~ "Source added."
    assert html =~ "Story"
    assert [%{tags: %{"items" => ["ai", "research"]}} = source] = Sources.list_sources()

    html =
      view
      |> element("button[phx-click='delete_source'][phx-value-id='#{source.id}']")
      |> render_click()

    assert html =~ "No sources configured yet"
    assert [] = Sources.list_sources()
  end
end
