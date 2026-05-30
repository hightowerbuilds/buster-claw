defmodule BusterClawWeb.SplitLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders two joined views side-by-side", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/split?left=/browse&right=/chat")

    assert html =~ "Split view"
    assert html =~ "Browse"
    assert html =~ "Chat"
    # The embedded Browse pane renders its own (bare) content.
    assert html =~ "Nothing loaded yet"
  end

  test "embedded panes render bare (no nested tab strip / dock)", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/split?left=/browse&right=/browse")

    # Only the outer split view draws the shell; panes are chromeless.
    assert occurrences(html, ~s(id="tab-strip")) == 1
    assert occurrences(html, ~s(id="app-dock")) == 1
  end

  test "unsupported views show a fallback instead of embedding", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/split?left=/mcp&right=/browse")

    assert html =~ "can&#39;t be opened in a split pane" or
             html =~ "can't be opened in a split pane"
  end

  test "renders a swap link with left/right swapped", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/split?left=/browse&right=/chat")

    # Swapped: left becomes /chat, right becomes /browse (slashes URL-encoded).
    assert has_element?(
             view,
             ~s(a[href="/split?left=%2Fchat&right=%2Fbrowse"]),
             "Swap panes"
           )
  end

  test "does not render a swap link when a pane is missing", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/split?left=/browse")

    refute html =~ "Swap panes"
  end

  test "each pane shows an Open as tab link to its own path", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/split?left=/browse&right=/chat")

    assert has_element?(view, ~s(a[href="/browse"]), "Open as tab")
    assert has_element?(view, ~s(a[href="/chat"]), "Open as tab")
  end

  test "a joined browse pane loads the url carried in its param", %{conn: conn} do
    Req.Test.stub(BusterClaw.BrowserHTTP, fn c ->
      Req.Test.html(
        c,
        "<html><head><title>Carried</title></head><body><p>Carried page body.</p></body></html>"
      )
    end)

    left = URI.encode_www_form("/browse?url=https://example.com/x")
    right = URI.encode_www_form("/chat")

    {:ok, _view, html} = live(conn, "/split?left=#{left}&right=#{right}")

    # The embedded Browse pane fetched and rendered the carried url.
    assert html =~ "Carried page body."
  end

  defp occurrences(haystack, needle), do: length(String.split(haystack, needle)) - 1
end
