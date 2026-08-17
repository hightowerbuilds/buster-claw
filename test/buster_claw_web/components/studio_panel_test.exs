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
    # The Studio moved off Home to its own route on 08-16, so this opens it
    # directly instead of clicking a home sub-tab that no longer exists.
    {:ok, view, html} = live(conn, ~p"/studio")
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

    # Was "the sub-tab selection survives a glance at Chat" until 08-16, when the
    # Studio left Home for `/studio`. The property is still real, but the threat
    # changed and the test has to name the one that exists now.
    #
    # **On Home the danger was the `:if`.** Every home panel renders behind one,
    # so switching to Chat destroyed the studio's DOM and its `live_component`
    # with it — the entire reason `studio_source`, the trim, the clipboard and
    # the undo stacks were hoisted into `StatusLive` in the first place.
    #
    # **On a route that danger is gone, and a different one replaces it:**
    # navigating away from `/studio` unmounts the LiveView, so the undo stack,
    # the trim and the clipboard do NOT survive it. That is a real behavioural
    # change, it is accepted — the mix itself is on disk, only in-progress
    # editing state is lost — and it is written here rather than discovered.
    # What must still hold is the sub-tab, across a switch inside the rail.
    test "the sub-tab selection survives a trip through another sub-tab", %{conn: conn} do
      {view, _html} = open_studio(conn)
      select_sub_tab(view, "voice")

      select_sub_tab(view, "mix")
      assert has_element?(view, "#studio-panel")

      select_sub_tab(view, "voice")

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

      # The sidebar was replaced by a menu bar on 08-16, so the source catalog is
      # behind File and Material rather than listed down the side. This used to
      # assert the group HEADINGS ("Recordings", "Music") were on screen; those
      # are submenu labels now, and an empty group is dropped rather than
      # rendered as a headed empty list — so asserting one is asserting the test
      # workspace has voicemails in it.
      assert has_element?(view, "#studio-menu-bar")
      assert has_element?(view, "#studio-menu-file")
      assert has_element?(view, "#studio-menu-material")
      assert html =~ "Open something from File or Material"
    end

    # Was "the Studio toolbar belongs to Mix". The toolbar is gone: its two
    # actions (New mix, Import) moved into the menu bar's File menu on 08-16, so
    # the verbs now live on the surface they act on instead of in the page chrome
    # above it. The property is unchanged — Mix's chrome must not follow you to
    # another sub-tab — and only the element it names has moved.
    test "the Mix menu bar belongs to Mix", %{conn: conn} do
      {view, _html} = open_studio(conn)
      assert has_element?(view, "#studio-menu-bar")

      select_sub_tab(view, "voice")
      refute has_element?(view, "#studio-menu-bar")

      select_sub_tab(view, "mix")
      assert has_element?(view, "#studio-menu-bar")

      # And the thing it replaced is really gone, not merely hidden.
      refute has_element?(view, "#studio-toolbar")
    end
  end

  describe "the Sketch Pad" do
    test "renders a canvas the browser owns, and no controls that lie", %{conn: conn} do
      {view, _html} = open_studio(conn)
      html = select_sub_tab(view, "sketch")

      assert has_element?(view, "#studio-sketch")

      # `phx-update="ignore"` is load-bearing rather than decorative: the hook
      # owns every pixel, and a LiveView re-render would wipe the drawing. If it
      # is ever removed, a stroke disappears on the next unrelated diff.
      assert has_element?(
               view,
               ~s(#studio-sketch-surface[phx-hook="SketchPad"][phx-update="ignore"])
             )

      assert has_element?(view, "#studio-sketch [data-sketch-canvas]")

      # Clear is destructive with no undo, so it takes the house confirm. This
      # is the opposite call from the dock's Stand down, which deliberately does
      # NOT confirm — the difference is whether hesitating is expensive.
      assert html =~ "data-claw-confirm"

      # The honest limit is on the surface, not buried in a tooltip. There is no
      # save, and a dead Save button would read as a broken feature. Asserted on
      # the CLAIM rather than its exact wording — the sentence was sharpened once
      # already (leaving the tab clears it too, not just a reload).
      assert html =~ "nothing is saved"
      refute html =~ "Save"
    end

    test "it is not the frozen studio wearing a different hat", %{conn: conn} do
      {view, _html} = open_studio(conn)
      select_sub_tab(view, "sketch")

      # Sub-tabs are alternatives. The `:if` must discard Mix entirely rather
      # than leaving it mounted and hidden — the same property the Voice tab is
      # asserted on, and the reason the studio's state lives in the LiveView.
      refute has_element?(view, "#studio-panel")
      refute has_element?(view, "#studio-toolbar")
    end
  end

  describe "the registry is the single source of truth" do
    test "tab_keys/0 is the registry, in rail order", %{conn: _conn} do
      assert StudioPanel.tab_keys() == Enum.map(Registry.tabs(), & &1.key)
      # A review-forcing snapshot: adding a rail button must fail here so
      # somebody looks. `sketch` joined 08-16 with the move to /studio.
      assert StudioPanel.tab_keys() == ["mix", "voice", "sketch"]

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

      assert literals == ["mix", "voice", "sketch"]

      for key <- literals do
        assert key in StudioPanel.tab_keys(),
               "#{key} is dispatched in studio_panel.ex but is not in the registry"
      end
    end
  end
end
