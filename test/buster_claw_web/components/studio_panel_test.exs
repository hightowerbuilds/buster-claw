defmodule BusterClawWeb.StudioPanelTest do
  # The Studio's sub-tab shell. One tab today — Mix — so what is asserted is
  # STRUCTURE: that the whitelist and the dispatch are views of one registry, and
  # that a single tab draws no rail.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClawWeb.Studio.Registry
  alias BusterClawWeb.StudioPanel

  # Same isolation as sound_studio_component_test: the studio reads a workspace,
  # and a test that shares the operator's would be a test that changes it.
  setup do
    root = Path.join(System.tmp_dir!(), "bc_studio_tabs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sounds"))

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    :ok
  end

  defp open_studio(conn) do
    # The Studio moved off Home to its own route on 08-16, so this opens it
    # directly instead of clicking a home sub-tab that no longer exists.
    {:ok, view, html} = live(conn, ~p"/studio")
    {view, html}
  end

  # Sent as an event rather than clicked: with one tab there is no rail button
  # to click. The handler and its whitelist are what is under test.
  defp select_sub_tab(view, key), do: render_click(view, "select_studio_tab", %{"tab" => key})

  describe "the rail" do
    # Two tabs until 09-19, when the Voice Library left with the cut-up engine
    # (`CUTUP_DELETION_ROADMAP`). One button that selects what is already
    # selected is a control that does nothing, so the rail is not drawn — and
    # this is the assertion that fails the day a second tab is added without
    # anyone deciding what the rail should look like again.
    test "is not drawn for a single tab, and Mix is what renders", %{conn: conn} do
      {view, _html} = open_studio(conn)

      assert length(Registry.tabs()) == 1
      refute has_element?(view, "#home-studio-tabs [role='tablist']")
      assert has_element?(view, "#home-studio-tabs [data-studio-tab='mix'] #studio-panel")
    end

    test "an unknown sub-tab key is refused, not crashed on", %{conn: conn} do
      {view, _html} = open_studio(conn)

      # The whitelist is StudioPanel.tab_keys/0 — a forged key leaves the current
      # sub-tab in place rather than blanking the panel or raising.
      select_sub_tab(view, "../../etc")
      assert has_element?(view, "#studio-panel")

      # `voice` was a real key until 09-19. An old client, or a bookmark of a
      # habit, must land on Mix rather than on an empty panel.
      select_sub_tab(view, "voice")
      assert has_element?(view, "#studio-panel")
      refute has_element?(view, "#studio-voice")
    end
  end

  describe "Mix" do
    test "renders the existing studio, unchanged, with its assigns", %{conn: conn} do
      {view, html} = open_studio(conn)

      # `#studio-panel` is SoundStudioComponent's own root, and `home-studio` is
      # the id `Studio.MixState.send_update/2` addresses — a rename here would break
      # the arranger silently.
      assert has_element?(view, "#studio-panel")
      assert has_element?(view, "#home-studio-tabs #studio-panel")

      # The source catalog is behind File and Material in the menu bar (08-16).
      assert has_element?(view, "#studio-menu-bar")
      assert has_element?(view, "#studio-menu-file")
      assert has_element?(view, "#studio-menu-material")
      assert html =~ "Open something from File or Material"

      # The toolbar the menu bar replaced is really gone, not merely hidden.
      refute has_element?(view, "#studio-toolbar")
    end

    test "nothing of the Voice Library survives on the page", %{conn: conn} do
      {view, html} = open_studio(conn)

      refute has_element?(view, "#studio-voice")
      refute has_element?(view, "#studio-recorder")
      refute html =~ "Voice Library"
    end
  end

  describe "the registry is the single source of truth" do
    test "tab_keys/0 is the registry, in rail order", %{conn: _conn} do
      assert StudioPanel.tab_keys() == Enum.map(Registry.tabs(), & &1.key)
      # A review-forcing snapshot: adding a rail button must fail here so
      # somebody looks. `sketch` joined 08-16 with the move to /studio and left
      # 09-05 when the Sketch Pad was deleted whole — which is this assertion
      # doing its job in the removing direction, where it is just as useful.
      # `voice` left the same way on 09-19.
      assert StudioPanel.tab_keys() == ["mix"]

      # Every tab is either built (it has a dispatch) or a placeholder — never
      # both, and never neither.
      #
      # **This list emptied on 08-14** when Voice was built, and an empty list
      # would make the `eyebrow`/`body` check below vacuously green — the
      # "a collection empties and its guard goes quiet" seam the doc-drift comb
      # named. So the emptiness is asserted directly: if a third sub-tab arrives
      # as a placeholder, this line fails and the copy check starts meaning
      # something again in the same commit.
      #
      # A third sub-tab arrived on 08-16 (Contribute, the recorder) and was
      # merged back into Voice the same day as the Voice Library's Record
      # section — so this is still `[]`, and the vacuous-guard risk below is
      # unchanged rather than resolved. Worth stating, because "the list is
      # still empty" reads like nothing happened, and twice today it did.
      placeholders = Enum.map(Registry.placeholders(), & &1.key)
      assert placeholders == []

      for %{key: key} = tab <- Registry.tabs() do
        assert is_binary(tab.label) and tab.label != ""
        assert is_binary(tab.blurb) and tab.blurb != ""

        if key in placeholders do
          # A placeholder needs the copy its page renders. Currently unreachable
          # by the assertion above, and deliberately kept: it is the contract a
          # new placeholder must satisfy on the day one appears.
          assert is_binary(tab.eyebrow) and is_binary(tab.body)
        end
      end
    end

    test "every registry tab has a dispatch, and every dispatch has a registry tab",
         %{conn: conn} do
      {view, _html} = open_studio(conn)

      # Forward: selecting any key in the registry renders a body that names
      # itself. A tab added to the registry with no dispatch line would render an
      # empty panel here, which is the failure this catches.
      for key <- StudioPanel.tab_keys() do
        select_sub_tab(view, key)

        assert has_element?(view, "#home-studio-tabs [data-studio-tab='#{key}']"),
               "sub-tab #{key} is in the registry but nothing dispatches on it"

        # Exactly one body at a time — the tabs are alternatives, not layers.
        for other <- StudioPanel.tab_keys(), other != key do
          refute has_element?(view, "[data-studio-tab='#{other}']")
        end
      end

      # Backward: a dispatch for a key the registry does not have would be
      # unreachable and therefore invisible to any render, so this direction is
      # asserted against the source. Same lockstep spirit as SettingsTabsTest,
      # and the only way to see an orphan. The placeholder's own marker is
      # `data-studio-tab={@sub_tab.key}` — registry-driven by construction, so
      # only the literals need checking.
      panel = Path.expand("../../../lib/buster_claw_web/components/studio_panel.ex", __DIR__)

      literals =
        ~r/data-studio-tab="([a-z_]+)"/
        |> Regex.scan(File.read!(panel))
        |> Enum.map(fn [_, key] -> key end)

      assert literals == ["mix"]

      for key <- literals do
        assert key in StudioPanel.tab_keys(),
               "#{key} is dispatched in studio_panel.ex but is not in the registry"
      end
    end
  end
end
