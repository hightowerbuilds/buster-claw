defmodule BusterClawWeb.PocketsPanelTest do
  @moduledoc """
  The Home → Pockets sub-tab, read-only (POCKETS_ROADMAP Phase 2b).

  Two levels on one screen, per D9: a list, and one Pocket open. These tests
  walk both, and they assert the three things the roadmap calls out by name —
  an invalid Pocket is drawn **as invalid** rather than dropped, the manifest
  body renders as prose, and the rail cannot offer a tab the guard refuses.
  """

  # async: false — points the global :workspace_root at a tmp directory.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Pockets

  setup do
    root = Path.join(System.tmp_dir!(), "bc_pockets_ui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "memory"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    # Same reason StatusLiveTest does it: without a detected CLI the home shell
    # renders an install prompt, and the assertions would depend on whether the
    # host has `claude` on PATH.
    prev_cli = Application.get_env(:buster_claw, :agent_cli)
    Application.put_env(:buster_claw, :agent_cli, {:claude, "/usr/local/bin/claude"})

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      Application.put_env(:buster_claw, :agent_cli, prev_cli)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp write_pocket(name, manifest, files \\ []) do
    dir = Pockets.pocket_dir(name)
    File.mkdir_p!(dir)
    if manifest, do: File.write!(Path.join(dir, "POCKET.md"), manifest)
    Enum.each(files, fn {file, body} -> File.write!(Path.join(dir, file), body) end)
    dir
  end

  defp open_tab(conn) do
    {:ok, view, _html} = live(conn, ~p"/")
    {view, render_click(view, "select_home_tab", %{"tab" => "pockets"})}
  end

  describe "the rail and the guard" do
    test "Pockets sits directly after Notes and the guard opens it", %{conn: conn} do
      keys = Enum.map(BusterClawWeb.StatusLive.home_tabs(), &elem(&1, 0))

      assert Enum.find_index(keys, &(&1 == "pockets")) ==
               Enum.find_index(keys, &(&1 == "notes")) + 1

      # The 08-08 lesson, walked rather than restated: the rail offering a key
      # the guard has never heard of is how Phone arrived as a button the
      # server refused. Clicking must both render the button as selected and
      # mount the panel.
      {view, _html} = open_tab(conn)

      assert has_element?(view, "button[phx-value-tab='pockets'].bg-primary")
      assert has_element?(view, "#home-pockets")
    end
  end

  describe "level one — the list" do
    test "each Pocket shows its name, kind, file count and a thumbnail strip",
         %{conn: conn} do
      write_pocket(
        "hazard-icons",
        """
        ---
        name: hazard-icons
        kind: icons
        description: Claw marks and hazard glyphs.
        roles: ["background"]
        ---

        The 32px versions are the ones that read at menu-bar size.
        """,
        [{"claw.png", "not really a png"}, {"claw-32.png", "nor is this"}]
      )

      write_pocket("scratch", """
      ---
      name: scratch
      kind: free
      description: Whatever.
      ---
      """)

      {view, html} = open_tab(conn)

      assert has_element?(view, "#pockets-list")
      assert has_element?(view, "#pocket-row-hazard-icons")
      assert has_element?(view, "#pocket-row-scratch")

      assert html =~ "hazard-icons"
      assert html =~ "icons"
      assert html =~ "2 files"
      # An empty Pocket says so rather than showing a bare zero.
      assert html =~ "empty"

      # Thumbnails go through the sanctioned asset route, never a file path —
      # both images in the strip, each cache-busted.
      assert html =~ ~s(src="/pockets/hazard-icons/claw.png?v=)
      assert html =~ ~s(src="/pockets/hazard-icons/claw-32.png?v=)
      refute html =~ Pockets.pocket_dir("hazard-icons")
    end

    test "an invalid Pocket renders AS INVALID, not absent", %{conn: conn} do
      # No manifest at all: the folder exists, so it must be visible.
      write_pocket("orphan", nil, [{"stray.png", "bytes"}])

      # A manifest naming something other than its directory.
      write_pocket("mislabelled", """
      ---
      name: something-else
      kind: icons
      ---
      """)

      # A kind the app has never heard of.
      write_pocket("odd", """
      ---
      name: odd
      kind: sculptures
      ---
      """)

      {view, html} = open_tab(conn)

      assert has_element?(view, "#pocket-invalid-orphan")
      assert has_element?(view, "#pocket-invalid-mislabelled")
      assert has_element?(view, "#pocket-invalid-odd")

      assert html =~ "no POCKET.md"
      assert html =~ "does not match the folder"
      assert html =~ "unknown kind"

      # Invalid means unopenable, not hidden: there is no button behind it.
      refute has_element?(view, "button[phx-value-name='orphan']")
    end

    test "with no Pockets at all the tab explains what one is", %{conn: conn} do
      {view, html} = open_tab(conn)

      assert has_element?(view, "#pockets-empty")
      refute has_element?(view, "#pockets-list")
      assert html =~ "No Pockets yet"
      assert html =~ "POCKET.md"
    end

    test "opening the tab creates the on-demand pockets directory", %{conn: conn} do
      refute File.dir?(Pockets.dir())
      open_tab(conn)
      assert File.dir?(Pockets.dir())
    end
  end

  describe "level two — one Pocket open" do
    setup do
      write_pocket(
        "hazard-icons",
        """
        ---
        name: hazard-icons
        kind: icons
        description: Claw marks and hazard glyphs.
        roles: ["background", "badge"]
        ---

        ## Regenerating

        `claw.png` is the master — regenerate the small ones from it.
        """,
        [{"claw.png", String.duplicate("x", 2048)}, {"notes.txt", "hi"}]
      )

      :ok
    end

    test "clicking a Pocket shows its contents, description, roles and body as prose",
         %{conn: conn} do
      {view, _html} = open_tab(conn)

      # Clicked as the operator does, through the row's own button — the event
      # is `phx-target`-ed at the component, and driving it at the LiveView
      # instead would test a handler that must not exist there.
      html = view |> element("#pocket-row-hazard-icons button") |> render_click()

      assert has_element?(view, "#pocket-open")
      refute has_element?(view, "#pockets-list")

      # The contents, with sizes.
      assert has_element?(view, "#pocket-contents")
      assert html =~ "claw.png"
      assert html =~ "notes.txt"
      assert html =~ "2.0 KB"

      # Description and roles.
      assert html =~ "Claw marks and hazard glyphs."
      assert html =~ "used by: background, badge"

      # The manifest body renders as prose — an <h2> from the Markdown, not the
      # raw `##`.
      assert has_element?(view, "#pocket-body h2")
      assert html =~ "regenerate the small ones from it"
      refute html =~ "## Regenerating"

      # An image kind still gets its strip at this level.
      assert has_element?(view, ~s(#pocket-strip img[src^="/pockets/hazard-icons/claw.png"]))
    end

    test "the back affordance returns to the list", %{conn: conn} do
      {view, _html} = open_tab(conn)
      view |> element("#pocket-row-hazard-icons button") |> render_click()

      assert has_element?(view, "#pocket-back")
      html = view |> element("#pocket-back") |> render_click()

      assert has_element?(view, "#pockets-list")
      refute has_element?(view, "#pocket-open")
      assert html =~ "hazard-icons"
    end

    test "the read-only phase offers no New, Mount or Delete", %{conn: conn} do
      # D9 puts those three in Phase 3, behind the mount registry. A button here
      # would be an affordance with nothing behind it.
      {view, html} = open_tab(conn)

      refute has_element?(view, "button[phx-click='new_pocket']")
      refute has_element?(view, "button[phx-click='mount_pocket']")
      refute has_element?(view, "button[phx-click='delete_pocket']")
      refute html =~ "Mount…"
    end
  end
end
