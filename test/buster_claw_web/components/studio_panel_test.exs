defmodule BusterClawWeb.StudioPanelTest do
  # The Studio tab's sub-tab shell: Mix (the existing studio) and Voice (a
  # placeholder). There are no features here yet, so everything below asserts
  # STRUCTURE — that the rail, the whitelist and the dispatch are the same three
  # views of one registry, and that switching tabs moves the two surfaces that
  # belong to Mix (the studio itself and its toolbar) rather than half of them.
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
    {:ok, view, _html} = live(conn, ~p"/")
    html = view |> element("button[phx-value-tab='studio']") |> render_click()
    {view, html}
  end

  defp select_sub_tab(view, key) do
    view |> element("button[phx-value-tab='#{key}']") |> render_click()
  end

  describe "the rail" do
    test "renders both sub-tabs, with Mix leading", %{conn: conn} do
      {view, html} = open_studio(conn)

      assert html =~ ~s(aria-label="Studio")
      assert html =~ "Mix"
      assert html =~ "Voice"

      for %{key: key, label: label, blurb: blurb} <- Registry.tabs() do
        assert has_element?(view, "#home-studio-tabs button[phx-value-tab='#{key}']"),
               "no rail button for #{label}"

        # The blurb is the button's tooltip, so a registry entry cannot carry
        # copy that nothing renders.
        assert html =~ blurb
      end

      assert has_element?(
               view,
               "#home-studio-tabs button[phx-value-tab='mix'][aria-selected='true']"
             )
    end

    test "an unknown sub-tab key is refused, not crashed on", %{conn: conn} do
      {view, _html} = open_studio(conn)

      # The whitelist is StudioPanel.tab_keys/0 — a forged key leaves the current
      # sub-tab in place rather than blanking the panel or raising.
      render_click(view, "select_studio_tab", %{"tab" => "../../etc"})

      assert has_element?(
               view,
               "#home-studio-tabs button[phx-value-tab='mix'][aria-selected='true']"
             )

      assert has_element?(view, "#studio-panel")
    end

    test "the sub-tab selection survives a glance at Chat", %{conn: conn} do
      # The assign lives in StatusLive, not in the `:if`-discarded panel. This is
      # the reason `Status.Studio` gives for owning every other studio assign.
      {view, _html} = open_studio(conn)
      select_sub_tab(view, "voice")

      render_click(view, "select_home_tab", %{"tab" => "chat"})
      refute has_element?(view, "#home-studio-tabs")

      render_click(view, "select_home_tab", %{"tab" => "studio"})

      assert has_element?(
               view,
               "#home-studio-tabs button[phx-value-tab='voice'][aria-selected='true']"
             )
    end
  end

  describe "the two tabs" do
    # Was "Voice renders the honest placeholder" until 08-14, then the Ramshackle
    # panes, and since 08-16 the Voice Library — a sidebar over three sections.
    # The two refutations are the half that has survived all three: whatever
    # Voice becomes, it must not drag the frozen studio along with it.
    test "Voice renders the Library, opening on Words, and no studio", %{conn: conn} do
      {view, _html} = open_studio(conn)
      html = select_sub_tab(view, "voice")

      assert has_element?(view, "#studio-voice")

      # The sidebar is the tab's own navigation — one activity, three steps.
      for key <- ~w(words sentence record) do
        assert has_element?(view, "[phx-click='voice_section'][phx-value-section='#{key}']"),
               "the Library sidebar has no #{key} section"
      end

      # It opens on Words, which is the only section rendered until one is picked.
      assert html =~ "Vocabulary"
      refute html =~ "Can it say this?"

      # The frozen component is gone, not merely hidden.
      refute has_element?(view, "#studio-panel")
      # And nothing pretends to work: no source list, no transport controls.
      refute html =~ "Pick something on the left"
    end

    test "the Library's sections are alternatives, not layers", %{conn: conn} do
      {view, _html} = open_studio(conn)
      select_sub_tab(view, "voice")

      html = render_click(element(view, "[phx-value-section='sentence']"))
      assert html =~ "Can it say this?"
      refute html =~ "Vocabulary"

      html = render_click(element(view, "[phx-value-section='record']"))
      assert has_element?(view, "#studio-recorder")
      refute html =~ "Can it say this?"
    end

    test "Mix renders the existing studio, unchanged, with its assigns", %{conn: conn} do
      {view, _html} = open_studio(conn)
      select_sub_tab(view, "voice")
      html = select_sub_tab(view, "mix")

      # `#studio-panel` is SoundStudioComponent's own root, and `home-studio` is
      # the id `Status.Studio.send_update/2` addresses — a rename here would break
      # the arranger silently.
      assert has_element?(view, "#studio-panel")
      assert has_element?(view, "#home-studio-tabs #studio-panel")
      assert html =~ "Recordings"
      assert html =~ "Music"
      assert html =~ "Pick something on the left"
    end

    test "the Studio toolbar belongs to Mix", %{conn: conn} do
      {view, _html} = open_studio(conn)
      assert has_element?(view, "#studio-toolbar")

      select_sub_tab(view, "voice")
      refute has_element?(view, "#studio-toolbar")

      select_sub_tab(view, "mix")
      assert has_element?(view, "#studio-toolbar")
    end
  end

  describe "the registry is the single source of truth" do
    test "tab_keys/0 is the registry, in rail order", %{conn: _conn} do
      assert StudioPanel.tab_keys() == Enum.map(Registry.tabs(), & &1.key)
      assert StudioPanel.tab_keys() == ["mix", "voice"]

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

      assert literals == ["mix", "voice"]

      for key <- literals do
        assert key in StudioPanel.tab_keys(),
               "#{key} is dispatched in studio_panel.ex but is not in the registry"
      end
    end
  end
end
