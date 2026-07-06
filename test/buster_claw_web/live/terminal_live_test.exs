defmodule BusterClawWeb.TerminalLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Settings
  alias BusterClaw.TerminalCommands

  test "renders the terminal host container with the xterm hook", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/terminal")

    assert html =~ "Terminal"
    assert has_element?(view, "[id^='terminal-root'][phx-hook='TerminalView']")
    assert has_element?(view, "[id^='terminal-root'][data-session-key='main']")
    assert has_element?(view, "[id^='terminal-root'][data-terminal-label='Terminal']")
    assert has_element?(view, "[data-terminal-toolbar][data-session-key='main']")
    assert has_element?(view, "[data-terminal-status]", "Connecting")
    assert has_element?(view, "[data-terminal-key]", "main")
    # Toolbar is now a single split (+) button, the session-key copy, and the
    # cmd-list cheat-sheet toggle. The directional split arrows + the separate
    # new-tab button were removed.
    assert has_element?(view, "button[data-terminal-action='split'][data-split-side='right']")
    refute has_element?(view, "button[data-terminal-action='new']")
    refute has_element?(view, "button[data-terminal-action='split'][data-split-side='left']")
    assert has_element?(view, "button[data-terminal-action='copy-key']")
    assert has_element?(view, "button[data-terminal-commands-button]", "cmd-list")
    # The shell-killing close button was removed; tabs/panes are closed via the
    # tab strip's × (and the per-pane × in a split), not from the terminal toolbar.
    refute has_element?(view, "button[data-terminal-action='close-shell']")

    assert has_element?(
             view,
             "button[data-terminal-commands-button][aria-label='Show command cheat sheet']"
           )

    refute has_element?(view, "[data-terminal-commands-menu]")
  end

  test "opens the terminal command dropdown from the toolbar button", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/terminal")

    refute has_element?(view, "[data-terminal-commands-menu]")

    view
    |> element("button[data-terminal-commands-button]")
    |> render_click()

    assert has_element?(view, "[data-terminal-commands-menu][role='menu']")
    assert has_element?(view, "[data-terminal-command-role='mailman']")
    assert has_element?(view, "[data-terminal-command='on-duty']", "Go On Duty")
    assert has_element?(view, "[data-terminal-command='off-duty']", "Off Duty")

    # Regression: a command with no :label/:description keys (welcome-introduction)
    # must render its prompt without crashing the cheat-sheet render.
    assert has_element?(view, "[data-terminal-command='welcome-introduction']")

    assert has_element?(
             view,
             "button[data-terminal-command-copy='#{TerminalCommands.startup_command("mailman")}']"
           )

    view
    |> element("button[data-terminal-commands-close]")
    |> render_click()

    refute has_element?(view, "[data-terminal-commands-menu]")
  end

  test "renders a route-scoped terminal session key and label", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/terminal?session=alpha&label=Alpha")

    assert has_element?(view, "[id^='terminal-root'][data-session-key='alpha']")
    assert has_element?(view, "[id^='terminal-root'][data-terminal-label='Alpha']")

    assert has_element?(
             view,
             "[id^='terminal-root'][data-terminal-path='/terminal?session=alpha&label=Alpha']"
           )

    assert has_element?(view, "[data-terminal-toolbar][data-terminal-label='Alpha']")
  end

  test "standalone terminal paints its own configured background", %{conn: conn} do
    put_terminal_background()

    {:ok, view, _html} = live(conn, ~p"/terminal")

    assert has_element?(
             view,
             "[data-terminal-session-shell][data-terminal-embedded='false'][data-terminal-bg-active='true']"
           )

    assert has_element?(
             view,
             "[id^='terminal-root'][data-terminal-embedded='false'][data-terminal-bg-active='true'][data-terminal-bg-source='host'][data-terminal-bg-image='/appearance/terminal-background/1?v=123']"
           )
  end

  test "renders the mailman startup profile as a fixed terminal command", %{conn: conn} do
    {:ok, view, _html} =
      live(conn, "/terminal?session=mailman&label=Mailman&startup_profile=mailman")

    assert has_element?(view, "[id^='terminal-root'][data-startup-profile='mailman']")

    assert has_element?(
             view,
             "[id^='terminal-root'][data-startup-command='#{TerminalCommands.startup_command("mailman")}']"
           )

    assert has_element?(
             view,
             "[id^='terminal-root'][data-terminal-path='/terminal?session=mailman&label=Mailman&startup_profile=mailman']"
           )
  end

  test "sanitizes route-scoped terminal session keys", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/terminal?session=bad%20key!&label=Bad")

    assert has_element?(view, "[id^='terminal-root'][data-session-key='bad-key']")
  end

  test "the dock Terminal button opens a fresh shell (hook-driven, not a plain link)", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    # It's a DockNewTerminal hook button (JS mints a unique session + tab per
    # click), not a navigate link to the shared /terminal "main" shell.
    assert has_element?(view, "button#dock-new-terminal[phx-hook='DockNewTerminal']")
    refute has_element?(view, "#app-dock a[href='/terminal']")
  end

  defp put_terminal_background do
    Settings.put("terminal_background_1_path", "appearance/test.png")
    Settings.put("terminal_background_1_updated_at", "123")
    Settings.put("terminal_background_active", "1")
  end

  test "terminal commands button is not rendered outside terminal routes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "[data-terminal-commands-button]")
  end
end
