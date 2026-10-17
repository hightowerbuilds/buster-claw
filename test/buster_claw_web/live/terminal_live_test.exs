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
    # The toolbar is the label, the status chip and the cmd-list toggle. The
    # split (+) and session-key copy buttons left on 10-15 (TERMINAL_PANELS D6):
    # terminals open as work-area panels now, and the key is the hook's business.
    refute has_element?(view, "[data-terminal-action]")
    refute has_element?(view, "[data-terminal-key]")
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

  # A terminal has no background of its own (it did until 10-17): it sits on
  # the app background. A standalone tab is the one place nothing else paints
  # that field, so the terminal paints it itself.
  test "a standalone terminal paints the app background itself", %{conn: conn} do
    put_home_background()

    {:ok, view, _html} = live(conn, ~p"/terminal")

    assert has_element?(
             view,
             "[data-terminal-session-shell][data-terminal-embedded='false'][data-terminal-bg-active='true']"
           )

    assert has_element?(
             view,
             "[id^='terminal-root'][data-terminal-embedded='false'][data-terminal-bg-active='true'][data-terminal-bg-source='host'][data-terminal-bg-image='#{BusterClaw.Appearance.background(:home).image_url}']"
           )
  end

  test "a standalone terminal runs the background's shader on its own canvas", %{conn: conn} do
    {:ok, _} = BusterClaw.Appearance.set_background(:home, "waves")

    {:ok, view, _html} = live(conn, ~p"/terminal")

    assert has_element?(view, "[id^='terminal-shader-waves']")
    assert has_element?(view, "[id^='terminal-root'][data-terminal-bg-source='shader']")
  end

  test "a standalone terminal with the background off is opaque", %{conn: conn} do
    {:ok, _} = BusterClaw.Appearance.set_background(:home, "off")

    {:ok, view, _html} = live(conn, ~p"/terminal")

    assert has_element?(
             view,
             "[id^='terminal-root'][data-terminal-bg-active='false'][data-terminal-bg-source='none']"
           )
  end

  test "the terminal follows a background change live", %{conn: conn} do
    {:ok, _} = BusterClaw.Appearance.set_background(:home, "off")
    {:ok, view, _html} = live(conn, ~p"/terminal")
    refute has_element?(view, "[id^='terminal-shader-']")

    {:ok, _} = BusterClaw.Appearance.set_background(:home, "mandel")

    assert has_element?(view, "[id^='terminal-shader-mandel']")
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

  test "Terminal opens in the work area with a persistent session", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "select_home_tab", %{"tab" => "terminal"})
    terminal = find_live_child(view, "workbench-terminal")
    assert has_element?(view, "#workbench-pane-terminal:not([hidden])")
    assert has_element?(terminal, "[phx-hook='TerminalView'][data-session-key='workbench']")
    assert has_element?(terminal, "[data-terminal-bg-active='true']")
    refute has_element?(view, "#app-dock a[href='/terminal']")
  end

  defp put_home_background do
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
    Settings.put("home_background_mode", "image:1")
  end

  test "terminal commands button is not rendered outside terminal routes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "[data-terminal-commands-button]")
  end
end
