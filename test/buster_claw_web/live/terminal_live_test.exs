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
    assert has_element?(view, "button[data-terminal-action='new'][aria-label='New terminal']")
    assert has_element?(view, "button[data-terminal-action='split'][data-split-side='left']")
    assert has_element?(view, "button[data-terminal-action='split'][data-split-side='right']")
    assert has_element?(view, "button[data-terminal-action='copy-key']")
    assert has_element?(view, "button[data-terminal-action='close-shell']")

    assert has_element?(
             view,
             "button[data-terminal-commands-button][aria-label='Show terminal commands']"
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
    assert has_element?(view, "[data-terminal-command='poll']", "Poll Gmail")
    assert has_element?(view, "[data-terminal-command='poll-shift-log']", "Poll + Shift Log")

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
             "[id^='terminal-root'][data-terminal-embedded='false'][data-terminal-bg-active='true'][data-terminal-bg-source='host'][data-terminal-bg-image='/appearance/terminal-background?v=123']"
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

  test "terminal is reachable from the dock nav", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(href="/terminal")
  end

  defp put_terminal_background do
    Settings.put("terminal_background_path", "appearance/test.png")
    Settings.put("terminal_background_updated_at", "123")
  end

  test "terminal commands button is not rendered outside terminal routes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "[data-terminal-commands-button]")
  end
end
