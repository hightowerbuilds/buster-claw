defmodule BusterClawWeb.SplitLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders two joined views side-by-side", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/split?left=/browse&right=/calendar")

    assert html =~ "Browse"
    assert html =~ "Calendar"
    # The embedded Browse pane renders its own (bare) content.
    assert html =~ "Nothing loaded yet"
    # In a joined pane the browser drops its page header.
    refute html =~ "Fetch and read pages in-app"
  end

  test "the terminal can be opened in a split pane", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/split?left=/terminal&right=/browse")

    assert html =~ "Terminal"
    # The embedded terminal pane renders its xterm host (not the fallback).
    assert html =~ ~s(phx-hook="TerminalView")
    assert html =~ ~s(data-session-key="main")
    refute html =~ "can't be opened in a split pane"
    # In a joined pane it's just the terminal window — no page header.
    refute html =~ "A live shell running"
  end

  test "split terminal panes preserve distinct session params", %{conn: conn} do
    left = URI.encode_www_form("/terminal?session=alpha&label=Alpha")
    right = URI.encode_www_form("/terminal?session=beta&label=Beta")

    {:ok, _view, html} = live(conn, "/split?left=#{left}&right=#{right}")

    assert html =~ ~s(id="split-pane-left-terminal-alpha")
    assert html =~ ~s(id="split-pane-right-terminal-beta")
    assert html =~ ~s(data-session-key="alpha")
    assert html =~ ~s(data-terminal-label="Alpha")
    assert html =~ ~s(data-session-key="beta")
    assert html =~ ~s(data-terminal-label="Beta")
  end

  test "embedded panes render bare (no nested tab strip / dock)", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/split?left=/browse&right=/browse")

    # Only the outer split view draws the shell; panes are chromeless.
    assert occurrences(html, ~s(id="tab-strip")) == 1
    assert occurrences(html, ~s(id="app-dock")) == 1
  end

  test "unsupported views show a fallback instead of embedding", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/split?left=/setup&right=/browse")

    assert html =~ "can&#39;t be opened in a split pane" or
             html =~ "can't be opened in a split pane"
  end

  test "panes carry no inline chrome (no Open as tab, no Split view header, no swap link)",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, "/split?left=/browse&right=/calendar")

    refute html =~ "Open as tab"
    refute html =~ "Split view"
    refute html =~ "Swap panes"
  end

  test "a joined browse pane loads the url carried in its param", %{conn: conn} do
    Req.Test.stub(BusterClaw.BrowserHTTP, fn c ->
      Req.Test.html(
        c,
        "<html><head><title>Carried</title></head><body><p>Carried page body.</p></body></html>"
      )
    end)

    left = URI.encode_www_form("/browse?url=https://example.com/x")
    right = URI.encode_www_form("/calendar")

    {:ok, _view, html} = live(conn, "/split?left=#{left}&right=#{right}")

    # The embedded Browse pane fetched and rendered the carried url.
    assert html =~ "Carried page body."
  end

  test "orchestration can be joined with the terminal (both bare)", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/split?left=/terminal&right=/orchestration")

    assert html =~ "Terminal"
    assert html =~ "Orchestration"
    # Both panes are embedded → only the outer split view draws the shell.
    assert occurrences(html, ~s(id="tab-strip")) == 1
    assert occurrences(html, ~s(id="app-dock")) == 1
  end

  test "every workspace tab embeds alongside the terminal without crashing", %{conn: conn} do
    for path <-
          ~w(/orchestration /integrations /mcp /webhooks /hooks /delivery /advanced
             /security /settings /appearance /calendar /gws /memory /scheduler /workspace) do
      assert {:ok, _view, _html} = live(conn, "/split?left=/terminal&right=#{path}"),
             "expected #{path} to embed in a split pane"
    end
  end

  defp occurrences(haystack, needle), do: length(String.split(haystack, needle)) - 1
end
