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
             "[id^='terminal-root'][data-terminal-embedded='true'][data-terminal-bg-source='host'][data-terminal-bg-image='#{BusterClaw.Appearance.background(:terminal).image_url}']"
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
             "[id^='terminal-root'][data-terminal-embedded='true'][data-terminal-bg-source='host'][data-terminal-bg-image='#{BusterClaw.Appearance.background(:terminal).image_url}']"
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

  # A join that includes Home: the homepage background is the one thing the
  # operator sees behind everything, so the split paints it ONCE across the whole
  # tab and the panes sit on it — the Home pane transparent (its own panels are
  # already veils), every other pane a translucent veil. Reported 10-13: a
  # terminal joined with Home was a solid block beside the shader.
  test "home joined with a terminal shares the home background across the split",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/split?left=/&right=/terminal")

    assert has_element?(view, "#split-root.ic-home[data-split-bg-field='home']")
    assert has_element?(view, "#split-root [id^='split-shader-']")
    # The Home pane does not draw a second copy of the same shader.
    refute has_element?(view, "[data-split-pane='left'] [id^='home-shader-']")

    assert has_element?(view, "[data-split-pane='left'][data-split-pane-veiled='false']")

    assert has_element?(
             view,
             "[data-split-pane='right'][data-split-pane-terminal='true'][data-split-pane-veiled='true']"
           )

    # The terminal goes transparent over the shared field, with no host image.
    assert has_element?(
             view,
             "[id^='terminal-root'][data-terminal-embedded='true'][data-terminal-bg-active='true'][data-terminal-bg-source='shared'][data-terminal-bg-image='']"
           )
  end

  test "a home split without a terminal still fills the field", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/split?left=/browse&right=/")

    assert has_element?(view, "#split-root[data-split-bg-field='home']")
    assert has_element?(view, "[data-split-pane='left'][data-split-pane-veiled='true']")
    assert has_element?(view, "[data-split-pane='right'][data-split-pane-veiled='false']")
  end

  test "an active terminal background outranks the home field", %{conn: conn} do
    put_terminal_background()

    {:ok, view, _html} = live(conn, "/split?left=/&right=/terminal")

    assert has_element?(view, "#split-root[data-split-bg-field='terminal']")
    refute has_element?(view, "#split-root.ic-home")
    # Home keeps its own canvas and its normal, opaque pane.
    assert has_element?(view, "[data-split-pane='left'] [id^='home-shader-']")
    assert has_element?(view, "[data-split-pane='left'][data-split-pane-veiled='false']")

    assert has_element?(
             view,
             "[id^='terminal-root'][data-terminal-embedded='true'][data-terminal-bg-source='host']"
           )
  end

  test "a home background set to off leaves the split plain", %{conn: conn} do
    {:ok, _} = BusterClaw.Appearance.set_background(:home, "off")

    {:ok, view, _html} = live(conn, "/split?left=/&right=/terminal")

    assert has_element?(view, "#split-root[data-split-bg-field='none']")
    assert has_element?(view, "[data-split-pane='right'][data-split-pane-veiled='false']")
    refute has_element?(view, "[id^='terminal-root'][data-terminal-bg-source='shared']")
  end

  test "embedded panes render bare (no nested tab strip / dock)", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/split?left=/browse&right=/browse")

    # Only the outer split view draws the shell; panes are chromeless.
    assert occurrences(html, ~s(id="tab-strip")) == 1
    assert occurrences(html, ~s(id="app-sidebar")) == 1
  end

  test "two joined browsers get independent left/right native surfaces", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/split?left=/browse&right=/browse")

    # Each pane drives its own native browser surface (distinct ids + surface tags)
    # so the two browsers stay independent side by side.
    assert html =~ ~s(id="browse-shell-left")
    assert html =~ ~s(id="browse-shell-right")
    assert html =~ ~s(data-surface-id="left")
    assert html =~ ~s(data-surface-id="right")
  end

  test "unsupported views show a fallback instead of embedding", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/split?left=/setup&right=/browse")

    assert html =~ "can&#39;t be opened in a split pane" or
             html =~ "can't be opened in a split pane"
  end

  test "a joined browser reuses the existing solo native surface", %{conn: conn} do
    browser = URI.encode_www_form("/browse?t=existing&surface=main")
    {:ok, view, _html} = live(conn, "/split?left=/&right=#{browser}")

    assert has_element?(
             view,
             "[data-split-pane='right'] #browse-shell-main[data-surface-id='main']"
           )
  end

  test "a separated browser keeps its former pane surface", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/browse?surface=left")
    assert has_element?(view, "#browse-shell-left[data-surface-id='left']")
  end

  test "an old speech split opens Speech and preserves its browser neighbor", %{conn: conn} do
    browser = URI.encode_www_form("/browse?t=existing&surface=main&url=https://example.com/keep")
    {:ok, view, _html} = live(conn, "/split?left=/voice&right=#{browser}")

    assert has_element?(view, "[data-split-pane='left'] #settings-speech-left-picker")

    assert has_element?(
             view,
             "[data-split-pane='right'] #browse-shell-main[data-surface-id='main']"
           )

    assert has_element?(
             view,
             "[data-split-pane='right'] [data-initial-url='https://example.com/keep']"
           )

    refute has_element?(view, "[phx-hook='VoiceRecorder']")
  end

  test "the recovered speech destination also opens in a split", %{conn: conn} do
    speech = URI.encode_www_form("/settings?tab=speech")
    {:ok, view, _html} = live(conn, "/split?left=/terminal&right=#{speech}")

    assert has_element?(view, "[data-split-pane='right'] #settings-speech-right-picker")
    assert has_element?(view, "[data-split-pane='left'] [data-session-key='main']")
  end

  for right <- ["/voice", "/settings"] do
    test "recovered Speech beside #{right} has independent Settings rails", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/split?left=/voice&right=#{unquote(right)}")
      left = find_live_child(view, "split-pane-left")
      right = find_live_child(view, "split-pane-right")

      for side <- ["left", "right"] do
        assert has_element?(view, "#split-#{side}-settings")
        assert has_element?(view, "#split-#{side}-settings-tabs")
        assert has_element?(view, "#split-#{side}-settings-tab-configuration")
        assert has_element?(view, "#split-#{side}-settings-config-rail")
      end

      refute has_element?(view, "#settings")
      refute has_element?(view, "#settings-tabs")
      refute has_element?(view, "#settings-config-rail")

      right |> element("#split-right-settings-config-tab-speech") |> render_click()
      left |> element("#split-left-settings-config-tab-profile") |> render_click()

      assert has_element?(left, "#split-left-settings-config-tab-profile[aria-selected='true']")
      assert has_element?(right, "#split-right-settings-config-tab-speech[aria-selected='true']")
      assert has_element?(right, "#settings-speech-right-picker")
      refute has_element?(left, "#settings-speech-left-picker")
    end
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
    assert occurrences(html, ~s(id="app-sidebar")) == 1
  end

  test "every workspace tab embeds alongside the terminal without crashing", %{conn: conn} do
    for path <-
          ~w(/ /browse /calendar /workspace
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
    # Home (StatusLive) content renders embedded — its corner widget.
    assert has_element?(view, "#home-corner-widget")
  end

  defp put_terminal_background do
    # A real file in a tmp workspace: slot URLs are stamped from the file's
    # mtime (and require it to exist) since the shared-DataZone cache fix.
    root = Path.join(System.tmp_dir!(), "bc_termbg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "pockets/backgrounds"))
    File.write!(Path.join(root, "pockets/backgrounds/test.png"), "png-bytes")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    Settings.put("background_image_1_path", "pockets/backgrounds/test.png")
    Settings.put("background_image_1_updated_at", "123")
    Settings.put("terminal_background_mode", "image:1")
  end

  defp occurrences(haystack, needle), do: length(String.split(haystack, needle)) - 1
end
