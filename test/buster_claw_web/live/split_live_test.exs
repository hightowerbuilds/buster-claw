defmodule BusterClawWeb.SplitLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Settings

  test "renders two joined views side-by-side", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/split?left=/browse&right=/calendar")

    assert html =~ "Browse"
    assert html =~ "Calendar"
    # The embedded Browse pane renders its (bare) browser shell.
    assert html =~ "data-browser-surface"
  end

  test "joined views render a draggable resize divider with a swap control", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/split?left=/browse&right=/calendar")

    assert has_element?(view, "#split-root[phx-hook='SplitResizer']")
    assert has_element?(view, "[data-split-divider]")
    assert has_element?(view, "[data-split-swap]")
  end

  test "each joined pane has its own close button", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/split?left=/browse&right=/calendar")

    assert has_element?(view, "[data-split-close='left']")
    assert has_element?(view, "[data-split-close='right']")
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

  test "two joined terminals share one continuous background", %{conn: conn} do
    put_terminal_background()

    {:ok, view, _html} = live(conn, "/split?left=/terminal&right=/terminal")

    assert has_element?(
             view,
             "#split-root[data-split-terminal-bg-active='true'][data-terminal-bg-active='true']"
           )

    assert has_element?(
             view,
             "[data-split-pane='left'][data-split-pane-terminal='true'][data-terminal-bg-active='true']"
           )

    assert has_element?(
             view,
             "[data-split-pane='right'][data-split-pane-terminal='true'][data-terminal-bg-active='true']"
           )

    # Each terminal self-paints the image on its own host; continuity comes from
    # the JS anchoring it to the viewport (background-attachment: fixed).
    assert has_element?(
             view,
             "[id^='terminal-root'][data-terminal-embedded='true'][data-terminal-bg-source='host'][data-terminal-bg-image='/appearance/terminal-background/1?v=123']"
           )
  end

  test "mixed terminal splits keep non terminal panes opaque", %{conn: conn} do
    put_terminal_background()

    {:ok, view, _html} = live(conn, "/split?left=/terminal&right=/browse")

    # Regression: the joined terminal paints its own background image even next to
    # a non-terminal pane — it no longer depends on the shared container showing
    # through (which the opaque neighbor would block).
    assert has_element?(
             view,
             "[id^='terminal-root'][data-terminal-embedded='true'][data-terminal-bg-source='host'][data-terminal-bg-image='/appearance/terminal-background/1?v=123']"
           )

    assert has_element?(
             view,
             "#split-root[data-split-terminal-bg-active='true'][data-terminal-bg-active='true']"
           )

    assert has_element?(
             view,
             "[data-split-pane='left'][data-split-pane-terminal='true'][data-terminal-bg-active='true']"
           )

    assert has_element?(
             view,
             "[data-split-pane='right'][data-split-pane-terminal='false'][data-terminal-bg-active='false']"
           )
  end

  test "non terminal splits do not paint the terminal background", %{conn: conn} do
    put_terminal_background()

    {:ok, view, _html} = live(conn, "/split?left=/browse&right=/calendar")

    assert has_element?(
             view,
             "#split-root[data-split-terminal-bg-active='false'][data-terminal-bg-active='false']"
           )

    assert has_element?(
             view,
             "[data-split-pane='left'][data-split-pane-terminal='false'][data-terminal-bg-active='false']"
           )

    assert has_element?(
             view,
             "[data-split-pane='right'][data-split-pane-terminal='false'][data-terminal-bg-active='false']"
           )
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

  test "a joined browse pane seeds its address from the url carried in its param", %{conn: conn} do
    left = URI.encode_www_form("/browse?url=https://example.com/x")
    right = URI.encode_www_form("/calendar")

    {:ok, _view, html} = live(conn, "/split?left=#{left}&right=#{right}")

    # The embedded Browse pane carries the url into its address bar / hook.
    assert html =~ "https://example.com/x"
  end

  test "a workspace tab can be joined with the terminal (both bare)", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/split?left=/terminal&right=/calendar")

    assert html =~ "Terminal"
    assert html =~ "Calendar"
    # Both panes are embedded → only the outer split view draws the shell.
    assert occurrences(html, ~s(id="tab-strip")) == 1
    assert occurrences(html, ~s(id="app-dock")) == 1
  end

  test "every workspace tab embeds alongside the terminal without crashing", %{conn: conn} do
    for path <-
          ~w(/ /browse /calendar /gws /workspace
             /integrations /security /settings
             /appearance /manual) do
      assert {:ok, _view, _html} = live(conn, "/split?left=/terminal&right=#{path}"),
             "expected #{path} to embed in a split pane"
    end
  end

  test "Home can be joined and renders (not the unsupported fallback)", %{conn: conn} do
    {:ok, view, html} = live(conn, "/split?left=/&right=/integrations")

    refute html =~ "can&#39;t be opened in a split pane"
    refute html =~ "can't be opened in a split pane"
    # Home (StatusLive) content renders embedded — its daily-calendar panel.
    assert has_element?(view, "#home-daily-calendar")
  end

  defp put_terminal_background do
    Settings.put("terminal_background_1_path", "appearance/test.png")
    Settings.put("terminal_background_1_updated_at", "123")
    Settings.put("terminal_background_active", "1")
  end

  defp occurrences(haystack, needle), do: length(String.split(haystack, needle)) - 1
end
