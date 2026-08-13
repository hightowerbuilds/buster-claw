defmodule BusterClawWeb.RemoteNoticesTest do
  @moduledoc """
  Clinch Phase 5: *"Every unavailable surface gets an explicit remote-mode notice
  and a useful next step. **No empty xterm, invisible native browser, or dead
  Voice toggle ships.**"*

  All three are already true. **This is a guard, not a build** — the notices exist,
  and the risk is that they quietly stop existing before anyone is on a tunnel to
  notice.

  ## Why this is a real risk and not ceremony

  Two of these are hook↔markup contracts, and this repo has already paid for
  breaking one: a regex rename across `.ex` files severed a hook's selector and
  **the suite stayed green**, because `render_hook` never touches JS. `terminal.js`
  writes the string `"Desktop only"` into `[data-terminal-status]`; rename that
  attribute in a template tidy and the hook writes into nothing, which renders as
  an **empty xterm** — the exact thing the roadmap names.

  So each test asserts both halves where there are two: the element the hook writes
  into, and the copy the server renders on its own.

  ## What "a useful next step" means here

  A notice that only says "unavailable" makes a remote session feel broken. Each
  assertion below checks the copy says *where the feature does work*, because that
  is the difference between a limitation and a fault.
  """
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # The hook that writes it → the attribute it writes into → the file that must
  # render that attribute. A named inventory: adding a Tauri-only surface means
  # adding a row, which is the point.
  @hook_targets [
    # terminal.js reads `dataset.statusId` and resolves it with getElementById —
    # so the contract is the ATTRIBUTE that carries the id, not a data- selector.
    # Getting this wrong is how the first draft of this test asserted a selector
    # terminal.js has never used; the inventory check below caught it.
    {"assets/js/hooks/terminal.js", "statusId", "data-status-id",
     "lib/buster_claw_web/live/terminal_live.ex"},
    {"assets/js/hooks/clinch.js", "data-clinch-unavailable", "data-clinch-unavailable",
     "lib/buster_claw_web/components/clinch_panels.ex"},
    {"assets/js/hooks/voice.js", "data-voice-label", "data-voice-label",
     "lib/buster_claw_web/components/chat_panel.ex"}
  ]

  describe "hook-to-markup contracts" do
    test "every element a fallback hook writes into is actually rendered" do
      for {hook, js_ref, markup_attr, template} <- @hook_targets do
        assert File.read!(hook) =~ js_ref,
               "#{hook} no longer references #{js_ref} — this inventory is stale, " <>
                 "and a stale inventory guards nothing"

        assert File.read!(template) =~ markup_attr,
               """
               #{hook} depends on #{markup_attr}, and #{template} does not render it.

               The hook will write into nothing and fail silently — an empty xterm, a
               blank status, a control that does not respond. render_hook never
               touches JS, so no other test in this suite can see this.
               """
      end
    end
  end

  describe "the three surfaces the roadmap names by hand" do
    test "the terminal says it is desktop-only rather than showing an empty xterm" do
      # The string is the hook's, not the server's: terminal.js sets it when
      # window.__TAURI__ is absent, which is every plain browser including one
      # reached over a tunnel.
      assert File.read!("assets/js/hooks/terminal.js") =~ "Desktop only",
             "terminal.js no longer reports a desktop-only state. Without it a " <>
               "tunneled browser shows an xterm that never connects and never says why."
    end

    test "the in-app browser explains itself instead of rendering an invisible webview",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/browse")

      text = String.replace(html, ~r/\s+/, " ")

      assert text =~ "in-app browser runs in the Buster Claw desktop app",
             "the browse surface no longer explains that it needs the desktop app. " <>
               "The native webview is invisible in a plain browser, so without this " <>
               "the page reads as broken rather than as unavailable."
    end

    test "the voice toggle says where it works rather than sitting dead", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/voice")

      text = String.replace(html, ~r/\s+/, " ")

      assert text =~ "desktop app only",
             "the Voice settings page no longer says speech is desktop-only. A " <>
               "toggle that does nothing and says nothing is the 'dead Voice toggle' " <>
               "the roadmap names."
    end
  end

  describe "credential management degrades honestly" do
    # The Clinch's remote posture is the one row of Phase 5's capability matrix
    # that is a security property rather than a convenience: management must be
    # unavailable, and must SAY so rather than offering a control that fails.
    # There are TWO panels that hide themselves without Tauri — `clinch_panel`
    # and `app_keys_panel` — and each carries its own copy of the notice.
    #
    # So this COUNTS rather than matching. A `=~` over the whole page is happy
    # with one copy, which means the panel that actually regressed passes: I
    # proved that by regressing exactly one of them and watching this test stay
    # green. The count is derived from the markers in the component rather than
    # hardcoded, so a third self-hiding panel raises the bar on its own.
    test "every self-hiding credential panel ships its own notice", %{conn: conn} do
      panels =
        "lib/buster_claw_web/components/clinch_panels.ex"
        |> File.read!()
        |> then(&Regex.scan(~r/data-clinch-unavailable/, &1))
        |> length()

      assert panels >= 2,
             "expected at least the Clinch and app-keys panels to hide themselves " <>
               "without Tauri; found #{panels}. If a panel stopped hiding, it now " <>
               "shows a form that cannot work over a tunnel."

      {:ok, _view, html} = live(conn, ~p"/settings")
      text = String.replace(html, ~r/\s+/, " ")

      for {copy, why} <- [
            {"Credentials can only be changed on the Mac running Buster Claw",
             "Over a tunnel the form is hidden by the hook, so without the notice " <>
               "the panel is simply absent with no explanation."},
            # The useful next step: it must separate "you cannot manage
            # credentials here" from "this page is broken".
            {"This page is reachable, but adding or removing a credential is not",
             "Without it the notice says only 'unavailable', which reads as a fault."}
          ] do
        found = length(Regex.scan(~r/#{Regex.escape(copy)}/, text))

        assert found == panels,
               """
               #{panels} panels hide themselves without Tauri, but #{found} render:

                 "#{copy}"

               #{why}

               A panel that hides itself and says nothing is a blank space where
               credential management used to be.
               """
      end
    end
  end
end
