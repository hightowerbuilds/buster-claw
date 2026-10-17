defmodule BusterClawWeb.Status.ExplainedLiveTest do
  @moduledoc """
  The Explained panel as mounted at `/`: every tutorial read against the app.
  """
  use BusterClawWeb.HomeCase

  alias BusterClaw.Appearance
  alias BusterClaw.Commands
  alias BusterClaw.ModelPolicy

  describe "Explained panel" do
    test "the Explained sub-tab opens on Intro with a launcher tile per sub-tab",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_click(view, "select_home_tab", %{"tab" => "explained"})

      assert has_element?(view, "#workbench-pane-explained[data-active='true']")
      assert has_element?(view, "#home-explained")
      # Intro is the default sub-tab and carries the what-this-is copy.
      assert has_element?(
               view,
               "#home-explained button[phx-value-tab='intro'][aria-selected='true']"
             )

      assert html =~ "Learn the machine."

      # The 3-step onboarding moved here from the retired Settings Get Started
      # tab (08-02) — steps only, no quick-chat starters. It's a native
      # <details> collapsible, CLOSED by default (no `open` attribute).
      assert has_element?(view, "details#explained-get-started")
      refute has_element?(view, "details#explained-get-started[open]")

      # Step order: install a supported harness → chat → communications.
      assert [_, one, two, three] =
               String.split(html, ~r/<h3[^>]*>/) |> Enum.take(4)

      assert one =~ "Install a supported agent CLI"
      assert one =~ "Codex or OpenCode"
      assert one =~ "recommended one"
      assert two =~ "Chat with Buster Claw"
      assert three =~ "Set up communications"
      assert three =~ "Advanced setup"
      assert three =~ "still synced and archived"
      assert three =~ "trusted senders become Dispatch work"
      refute html =~ "Quick chat"

      # Every non-Intro sub-tab has a launcher tile (rail button + grid tile
      # both carry phx-value-tab, so each key appears at least twice).
      for key <- BusterClawWeb.ExplainedPanel.tab_keys(), key != "intro" do
        tiles =
          view
          |> render()
          |> then(&Regex.scan(~r/phx-value-tab="#{key}"/, &1))

        assert length(tiles) >= 2, "expected a rail button AND a tile for #{key}"
      end
    end

    test "the site tiles open tabs that carry the copy and the external link",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explained"})

      # busterclaw.lol: the download, the docs and the source — nothing sold,
      # nothing planned (EXPLAINED_REWRITE D4; the phone left 10-15).
      html = render_click(view, "select_explained_tab", %{"tab" => "site"})
      assert html =~ "free"
      assert html =~ "source-available"
      refute html =~ "phone number"
      refute html =~ "vending"
      assert html =~ "/browse?url=https%3A%2F%2Fbusterclaw.lol"

      html = render_click(view, "select_explained_tab", %{"tab" => "ntf"})
      assert html =~ "Notes That Float"
      assert html =~ "creative-writing and journaling app"
      assert html =~ "spatial, 3D view"
      assert html =~ "not Buster Claw&#39;s operator notebook"
      assert html =~ "/browse?url=https%3A%2F%2Fnotesthatfloat.com"
    end

    test "the Shaders tab teaches the file contract and that unseen GPU code needs your click",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explained"})

      html = render_click(view, "select_explained_tab", %{"tab" => "shaders"})

      assert html =~ "Shaders &amp; Backgrounds"
      assert html =~ ~s(href="/appearance")
      assert has_element?(view, "#explained-shader-catalog")
      assert has_element?(view, "#explained-shader-contract")

      # The catalog is rendered FROM Appearance, so it cannot describe a set of
      # built-ins or a pool size the module no longer has.
      for shader <- Appearance.builtin_shaders() do
        assert html =~ shader, "the Shaders tutorial does not name the #{shader} built-in"
      end

      assert html =~ "up to #{Appearance.max_images()} slots"

      # The claim the whole tab rests on, and it has now CHANGED TWICE rather
      # than dying — which is the argument for writing it this way. It used to be
      # "nothing on the command surface selects a background"; `background_list` /
      # `background_set` landed on 08-15 and this test failed, which is exactly
      # what it was written to do. It then became "an agent may never apply a
      # shader IT WROTE", and AGENT_APPLIED_SHADERS made that false too: a
      # workspace shader whose current bytes the operator has applied by hand is
      # now applicable by command.
      #
      # What survived both narrowings, and what the tab must keep teaching, is
      # that GPU code the operator has never looked at does not reach a screen on
      # the agent's say-so. So this asserts the surface has not grown a third
      # appearance-ish verb behind our backs — a shader-writing or
      # image-uploading one would break the property the tab teaches, and would
      # land here first.
      selectors =
        Commands.list_commands()
        |> Enum.filter(fn command ->
          String.starts_with?(command.name, "shader") or
            String.starts_with?(command.name, "appearance") or
            String.starts_with?(command.name, "background")
        end)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert selectors == ["background_list", "background_set"],
             """
             The appearance command surface changed. The Shaders tutorial teaches
             that an agent may point a surface at something that already exists
             but may never put GPU code the operator has not seen on a screen, and
             `Commands.Appearance` enforces that by refusing any shader that is
             neither a built-in nor approved at its current content hash.

             A new verb here needs that property re-argued, and this page
             rewritten. Found: #{Enum.join(selectors, ", ")}
             """

      # The tab says what the agent CAN do, and what it still cannot. The second
      # of these is the sentence that replaced "cannot apply a shader it wrote"
      # when approval-by-hash shipped: the narrower claim is the one that is
      # still true, so it is the one asserted.
      assert html =~ "background_set"
      assert html =~ "cannot put GPU code you have never looked at on your screen"

      # And the tab must teach the rule, not just the reassurance: built-ins
      # always, a workspace shader once YOU have applied it, and an edit puts it
      # back behind a click. A tutorial that stopped at "the agent can't" would
      # now be teaching a refusal the app no longer makes.
      assert html =~ "you have already applied yourself"
      assert html =~ "stays a proposal until you click it once in Appearance"
      assert html =~ "until the file changes"

      # Why the approval is a hash and not a name. This is the load-bearing half:
      # a name-keyed approval would let a run overwrite an approved file and ride
      # the blessing, which is the same file-write shortcut that made "no command
      # authors a shader" insufficient in the first place.
      assert html =~ "fingerprint of the file, not its name"
      assert html =~ "overwritten with different code and ride the blessing"

      # The backfill is stated, not hidden. Shaders already in the folder when
      # approval shipped were approved unclicked, so a page claiming every shader
      # runs first because the operator clicked it would be false for exactly the
      # 22 files most operators have. A tutorial that overstates the guarantee is
      # the failure this tab was rewritten to avoid.
      assert html =~ "because they predate the question"

      # The file contract, each part of it load-bearing.
      assert html =~ "fs_main"
      assert html =~ "64 KB"

      # Corrected 08-08 against the implementation: the catalog is click, and
      # there is no palette-coloured fallback — the layer simply does not paint.
      assert html =~ "a single click"

      # The tab has to name every surface it teaches about. Derived from
      # `Appearance.surfaces/0` rather than counted in prose, because the count
      # changed on 08-15 and a page that says "two" while the picker shows three
      # is the drift this whole day was spent on.
      # Scoped to the CATALOG SECTION, not the page. The first version asserted
      # against the whole homepage and passed with the surface deleted from the
      # tutorial — because the corner widget's own tab button also says "Time &
      # Place". A guard that the page satisfies for you is not a guard.
      #
      # Compared the way prose renders: case-insensitively, since a label reads
      # as "the homepage" mid-sentence, and with `&` escaped, since "Time &
      # Place" reaches the page as `Time &amp; Place`.
      section =
        view |> element("#explained-shader-catalog") |> render() |> String.downcase()

      for surface <- Appearance.surfaces() do
        label =
          Appearance.surface_label(surface)
          |> String.downcase()
          |> String.replace("&", "&amp;")

        assert section =~ label, "the Shaders tab never names the #{surface} surface"
      end

      refute html =~ "drag"
      assert html =~ "stays solid"

      refute html =~ "Tutorial in the works"
    end

    test "the Command List tab carries the whole catalog inline, not a link to it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explained"})

      html = render_click(view, "select_explained_tab", %{"tab" => "cmd"})

      assert has_element?(view, "#explained-command-atlas")

      # EVERY command, not a sample. This is the assertion the operator asked for
      # on 08-09 — the tutorial used to link out for the list, so the page could
      # go stale against the catalog without anything noticing. Now it cannot:
      # add a command anywhere in the catalog and it renders here, or this fails.
      commands = Commands.list_commands()
      missing = Enum.reject(commands, &(html =~ ~s(id="cmd-#{&1.name}")))

      assert missing == [],
             "#{length(missing)} command(s) are in the catalog but not on the page: " <>
               Enum.map_join(Enum.take(missing, 10), ", ", & &1.name)

      # The two links this replaced pointed at /cmd-list, which is NOT the command
      # catalog — it is `CmdListLive`, the terminal cheatsheet editor. That was a
      # reader following "browse the full command list" to an editor for something
      # else. Assert the tab does not send them there again.
      refute html =~ ~s(href="/cmd-list"),
             "the Command List tutorial links to /cmd-list, which edits the terminal " <>
               "cheatsheet and does not contain the command catalog"

      # Descriptions ride along, so the list is usable rather than an index.
      sample = Enum.find(commands, &(&1.name == "sound_apply"))
      assert html =~ String.slice(sample.description, 0, 60)
    end

    test "the Studio tab teaches the library, the routing table, and the one gated verb",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explained"})

      html = render_click(view, "select_explained_tab", %{"tab" => "studio"})

      assert has_element?(view, "#explained-studio-surfaces")
      assert has_element?(view, "#explained-studio-safety")
      assert html =~ ~s(href="/notify-settings")

      for cmd <- ~w(sound_routes sound_list sound_trim sound_fade sound_normalize
                    sound_concat sound_probe sound_apply) do
        assert html =~ ~s(data-terminal-command-copy="#{cmd}"),
               "the Studio tutorial does not offer #{cmd} as a copyable command"

        assert Commands.command_type(cmd) != nil,
               "tutorial names #{cmd}, which is not in the command catalog"
      end

      catalog = Map.new(Commands.list_commands(), &{&1.name, &1})

      # The claim this tutorial is built on: of everything the page teaches,
      # `sound_apply` alone crosses from "a file exists" to "the machine behaves
      # differently", and it is the one carrying the gate.
      #
      # Scoped to the verbs THIS PAGE names, deliberately. The first draft asserted
      # `sound_apply` was the only gated verb in the whole `sound_*` family, which
      # was true of HEAD and false the moment the capture work lands `sound_record`
      # — also gated, for an unrelated reason (it opens the microphone). That
      # version would have passed here and then failed in someone else's commit,
      # which is a worse defect than the one it was guarding against.
      assert Map.fetch!(catalog, "sound_apply") |> Map.get(:gated, false),
             "the Studio tutorial rests on sound_apply being gated"

      for name <- ~w(sound_routes sound_list sound_trim sound_fade sound_normalize
                     sound_concat sound_probe sound_import sound_delete
                     sound_restore_defaults) do
        refute Map.get(Map.fetch!(catalog, name), :gated, false),
               "the Studio tutorial teaches #{name} as a verb that writes and stops, " <>
                 "but it is now gated — the page's safety story needs rewriting"
      end

      # The counterweight, and it matters as much: the way back must NOT be gated.
      restore = Map.fetch!(catalog, "sound_restore_defaults")
      assert restore.type == :mutate
      refute Map.get(restore, :gated, false), "gating the undo strands whoever needs it"

      # The four editing verbs write a new source and nothing else — none of them
      # may quietly become the thing that changes what plays.
      for name <- ~w(sound_trim sound_fade sound_normalize sound_concat) do
        entry = Map.fetch!(catalog, name)
        assert entry.type == :mutate
        assert entry.tier == :restricted
        refute Map.get(entry, :gated, false), "#{name} writes a new source; it must not be gated"
      end

      refute html =~ "Tutorial in the works"
    end

    # Was "the Studio tab offers every cut-up verb, and each one exists" until
    # 09-19, when the cut-up engine, its verbs and the Voice Library half of the
    # page were deleted (`CUTUP_DELETION_ROADMAP`). The contract survives for the
    # verbs that are left: every command the tutorial offers must exist.
    test "the Studio tab offers only verbs that exist, and none of the cut-up's", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explained"})

      html = render_click(view, "select_explained_tab", %{"tab" => "studio"})

      offered =
        ~r/data-terminal-command-copy="([a-z_]+)"/
        |> Regex.scan(html, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()

      # Not vacuous: the page teaches the library, the four edits and the gate.
      for cmd <- ~w(sound_routes sound_list sound_trim sound_fade sound_normalize
                    sound_concat sound_probe sound_apply) do
        assert cmd in offered, "the Studio tutorial does not offer #{cmd} as a copyable command"
      end

      for cmd <- offered do
        assert Commands.command_type(cmd) != nil,
               "tutorial names #{cmd}, which is not in the command catalog"
      end

      # The deleted half must not leave a ghost in the copy — a tutorial naming
      # a tab that is gone is the drift this page keeps having.
      refute has_element?(view, "#explained-studio-cutup-verbs")
      refute html =~ "Voice Library"
      refute html =~ "Sketch Pad"

      # The framing is a contract, not decoration. Every other Explained tab
      # documents something the product depends on; this one documents a
      # workshop, and saying so is what buys the room to keep changing it. If
      # the Studio is ever presented as settled, this fails and somebody has to
      # decide whether that is true.
      assert html =~ "Experimental"
      assert html =~ "where this app tries things"

      refute html =~ "Tutorial in the works"
    end

    test "every Explained demo declares its contract and offers the two safe actions",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explained"})

      # The four fact rows are required attrs on `<.example>`, so a demo missing
      # one is a compile warning rather than a passing test. What this asserts is
      # the other half: that the rows actually REACH the page, on every tab that
      # has demos, and that the two safe actions ride along with each prompt.
      #
      # Derived, not listed. This was a hardcoded `~w(models shaders phone
      # browser cmd gws)` until 08-09, and the Ramshackle Voice tab landed
      # outside it — a seventh tutorial that this test went on passing without
      # ever rendering. A list of tabs maintained by hand is a guard that goes
      # quietly stale the moment the rail grows, which is the whole failure mode
      # `Explained.Registry` exists to prevent everywhere else.
      #
      # Intro is a launcher and the two site tabs are outbound links, so neither
      # carries demos; a stub tab has none either, by definition.
      stubs = Enum.map(BusterClawWeb.Explained.Registry.stubs(), & &1.key)
      tabs = BusterClawWeb.ExplainedPanel.tab_keys() -- (~w(intro site ntf) ++ stubs)

      # Seven since 10-15: the phone tutorial left with the phone.
      assert length(tabs) >= 7, "the demo-contract sweep lost tabs instead of gaining them"

      for tab <- tabs do
        html = render_click(view, "select_explained_tab", %{"tab" => tab})

        facts = Regex.scan(~r/data-demo-facts/, html)
        assert facts != [], "the #{tab} tutorial has no worked demos"

        for field <- ~w(needs touches confirm result) do
          rows = Regex.scan(~r/data-demo-#{field}/, html)

          assert length(rows) == length(facts),
                 "the #{tab} tutorial has #{length(facts)} demos but " <>
                   "#{length(rows)} #{field} rows"
        end

        # Copy prompt is always available; nothing on an Explained tab submits.
        assert html =~ "Copy prompt",
               "the #{tab} tutorial has no copyable prompt"

        refute html =~ ~s(phx-click="send"),
               "an Explained tutorial must never offer to submit anything"
      end
    end

    test "Try in Chat prefills the composer and does not submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explained"})
      render_click(view, "select_explained_tab", %{"tab" => "cmd"})

      # Clicking the button on a real tutorial prompt: it switches to Chat and
      # pushes the prefill event. Prefill only — the hook fills the input and the
      # operator presses send, which is what keeps opening a tutorial from ever
      # running a mutation.
      view
      |> element(~s([data-demo-try-in-chat][phx-value-text^="Save that plan"]))
      |> render_click()

      assert_push_event(view, "bc:chat_prefill", %{text: text})
      assert text =~ "Save that plan as a document"
      assert has_element?(view, "#workbench-pane-chat[data-active='true']")

      # A forged or oversized payload is refused rather than crashing the page —
      # same posture as the sub-tab whitelist beside it.
      render_click(view, "explained_try_in_chat", %{"text" => String.duplicate("x", 3000)})
      render_click(view, "explained_try_in_chat", %{})
      assert has_element?(view, "#home-agent-chat")
    end

    test "the GWS unattended cycle does not offer to paste an email into Chat",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explained"})

      html = render_click(view, "select_explained_tab", %{"tab" => "gws"})

      # That cycle's prompt is mail from a trusted sender, and the lesson is that
      # the trigger is the mail — offering "Try in Chat" on it would teach the
      # wrong mechanism. Every other prompt on the tab keeps the button.
      assert html =~ "You email — from your phone, hours later"

      prompts = Regex.scan(~r/data-demo-prompt/, html)
      buttons = Regex.scan(~r/data-demo-try-in-chat/, html)

      assert length(buttons) == length(prompts) - 1,
             "exactly one GWS prompt (the email) should omit Try in Chat — " <>
               "#{length(prompts)} prompts, #{length(buttons)} buttons"
    end

    test "the Models tab teaches the shape: unset, per surface, and the floor",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explained"})

      html = render_click(view, "select_explained_tab", %{"tab" => "models"})

      assert html =~ "Models — whose model, whose bill, and which surface"
      assert html =~ "ASKED PER SURFACE, FIRST MATCH WINS"

      # Fact 1: the CLI is the operator's, and so is the bill.
      assert html =~ "holds no Claude API key"
      assert html =~ "<code>claude</code>, <code>codex</code>"

      # Fact 2: unset means the flag is omitted, not that a default is missing.
      assert html =~ "--model"

      # Fact 3: the surface list is rendered FROM `ModelPolicy`, so it cannot
      # describe a surface set the policy no longer has. Assert every key lands
      # as its own token rather than as prose that happens to contain the word.
      for surface <- ModelPolicy.surface_keys() do
        assert html =~ ">#{surface}</span>",
               "the Models tutorial does not render the #{surface} surface"
      end

      # Fact 4: floors and claude-only pins render FROM the policy, so a surface
      # that declares one gets its badge without this tutorial being rewritten.
      # Both maps are empty since the trading stack left on 08-08 — these loops
      # are deliberately vacuous today and become real the moment one is
      # declared, which is the property worth keeping.
      for {_surface, floor} <- ModelPolicy.floors() do
        assert html =~ "floor: #{floor}"
      end

      for {surface, _reason} <- ModelPolicy.claude_only() do
        assert has_element?(
                 view,
                 "[data-model-surface='#{surface}'] [data-claude-only]"
               )
      end

      # Fact 5: where to change it — Settings, and the command.
      assert html =~ ~s(href="/settings")
      assert html =~ "<code>model_policy</code>"

      assert BusterClaw.Commands.command_type("model_policy") != nil,
             "the Models tutorial names model_policy, which is not in the command catalog"

      # The deferred Phase 4 items are named as absent, not implied as present.
      assert html =~ "no per-conversation model picker"
      assert html =~ "no per-surface or per-day total"
      assert html =~ "<code>codex</code>"

      # And the claim that replaced a FALSE one must not drift back. Every
      # harness does report what a run cost — claude's `result` event carries
      # `total_cost_usd`, measured 08-03. The tutorial said the opposite for
      # half a day because the roadmap said it and nobody ran the command.
      refute html =~ "does not report spend"

      refute html =~ "Tutorial in the works"
    end

    test "the Gmail/GWS tab is a real tutorial: prompts, real commands, no stub line",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explained"})

      html = render_click(view, "select_explained_tab", %{"tab" => "gws"})

      # The six cycles, prompt-first.
      assert html =~ "The morning brief"
      assert html =~ "Draft, don&#39;t send"
      assert html =~ "Remember the schedule"
      assert html =~ "The unattended cycle"
      assert html =~ "Make the files, not just the mail"
      assert html =~ "Send the file, not a link"
      assert html =~ "You type"

      # The explanation covers both connection paths and distinguishes archiving
      # ordinary mail from trusting a sender to create agent work.
      assert html =~ "bundled button when this build provides it"
      assert html =~ "Advanced setup"
      assert html =~ "Other mail is still synced and archived"

      # The security explanation is a contract with catalog metadata, not just
      # frozen prose. These three outbound paths use three different controls.
      catalog = Map.new(Commands.list_commands(), &{&1.name, &1})
      gmail_send = Map.fetch!(catalog, "gmail_send")
      drive_share = Map.fetch!(catalog, "drive_share")
      dispatch_reply = Map.fetch!(catalog, "dispatch_reply")

      assert gmail_send.type == :mutate
      assert gmail_send.tier == :restricted
      assert gmail_send.gated
      assert gmail_send.args["confirm_send"].required

      assert drive_share.type == :mutate
      assert drive_share.tier == :restricted
      refute Map.get(drive_share, :gated, false)
      assert drive_share.args["confirm_share"].required

      assert dispatch_reply.type == :mutate
      assert dispatch_reply.tier == :restricted
      refute Map.get(dispatch_reply, :gated, false)
      refute Map.has_key?(dispatch_reply.args, "confirm_send")

      assert html =~ "not a policy-gated command"
      assert html =~ "has no separate"
      refute html =~ "anything outbound — a send, a share — is gated"

      # Every command the copy names must exist in the catalog — the tutorial
      # is a contract with the command surface, enforced here so a rename
      # can't silently strand the docs.
      for cmd <- ~w(gmail_sync gmail_search gmail_read gmail_draft_create gmail_send
                    google_calendar_sync notify_create dispatch_reply
                    sheets_create sheets_append_values docs_create slides_create
                    slides_batch_update drive_folder_create drive_update drive_upload
                    drive_share drive_export) do
        assert html =~ "<code>#{cmd}</code>"

        assert BusterClaw.Commands.command_type(cmd) != nil,
               "tutorial names #{cmd}, which is not in the command catalog"
      end

      # Graduated from stub status: no placeholder line.
      refute html =~ "Tutorial in the works"
    end

    test "the Command List tab is the atlas: renamed, diagrammed, real commands",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explained"})

      html = render_click(view, "select_explained_tab", %{"tab" => "cmd"})

      # Renamed from "Cmd & Promptship" (operator, 08-02).
      assert html =~ "Command List"
      refute html =~ "Promptship"

      # The taxonomy is rendered from the catalog's three independent axes.
      assert has_element?(view, "#explained-command-taxonomy")
      assert has_element?(view, "#explained-command-operation-types")
      assert has_element?(view, "#explained-command-trust-tiers")
      assert has_element?(view, "#explained-command-policy-flags")

      commands = Commands.list_commands()
      types = Enum.frequencies_by(commands, & &1.type)
      tiers = Enum.frequencies_by(commands, & &1.tier)
      gated = Enum.count(commands, &Map.get(&1, :gated, false))

      assert element(view, "#explained-command-total") |> render() =~ to_string(length(commands))
      assert html =~ "#{Map.fetch!(types, :read)} read"
      assert html =~ "#{Map.fetch!(types, :trigger)} trigger"
      assert html =~ "#{Map.fetch!(types, :mutate)} mutate"
      assert html =~ "#{Map.fetch!(tiers, :safe)} safe"
      assert html =~ "#{Map.fetch!(tiers, :restricted)} restricted"
      assert html =~ "#{gated} commands are additionally"
      assert html =~ "Gated is a flag, not a third"
      refute html =~ "every tab, every feature"
      refute html =~ "nothing leaves the machine"

      # The funnel SVG uses the same corrected audit boundary.
      assert html =~ "SENTINEL AUDIT FEED"
      assert html =~ "MUTATES + TRIGGERS"
      assert html =~ ~s(role="img")

      # The five examples (the phone desk left with the phone, 10-15).
      # Cycle 2 was "The market at a glance" until 08-08, when
      # the operator took trading out of what Explained teaches. The finance_*
      # commands still exist and are still on /cmd-list — the atlas simply stopped
      # leading a first-time user there, so this asserts the market cycle is GONE
      # rather than merely that the notebook one is present.
      assert html =~ "Capture the day"
      assert html =~ "The notebook and the vault"
      assert html =~ "Web errands, hands off the wheel"
      assert html =~ "The queue is the desk"
      assert html =~ "It learns your routines"

      refute html =~ "The market at a glance"

      for cmd <- ~w(finance_quote finance_news finance_fundamentals finance_filings) do
        refute html =~ "<code>#{cmd}</code>",
               "the atlas should no longer teach #{cmd} — trading is out (08-08)"
      end

      # Same contract as the GWS tutorial: every named command must exist.
      for cmd <- ~w(document_save journal_append notify_create
                    note_search note_read note_save note_create note_list
                    web_search browser_fetch bookmark_add
                    dispatch_enqueue dispatch_list dispatch_claim dispatch_done
                    memory_search
                    skill_analyze skill_suggestions skill_suggestion_approve) do
        assert html =~ "<code>#{cmd}</code>"

        assert BusterClaw.Commands.command_type(cmd) != nil,
               "tutorial names #{cmd}, which is not in the command catalog"
      end

      # "The phone desk" cycle left with the phone (10-15); nothing in the atlas
      # may still teach a phone verb or promise a text back.
      refute html =~ "sms_send"
      refute html =~ "phone_"
      refute html =~ "BusterPhone"

      # The replacement cycle's own claim is a contract too: the note verbs are
      # restricted precisely because note titles are the operator's private
      # writing, so `note_list` being safe-tier would falsify the copy.
      catalog = Map.new(Commands.list_commands(), &{&1.name, &1})

      for name <- ~w(note_list note_read note_search note_create note_save) do
        assert Map.fetch!(catalog, name).tier == :restricted,
               "#{name} must stay restricted — the tutorial says even listing isn't safe-tier"
      end

      assert Map.fetch!(catalog, "note_save").args["revision"].required,
             "the tutorial teaches note_save's revision guard; it must stay required"

      refute html =~ "Tutorial in the works"
    end

    test "the BrowserControl tab teaches the three surfaces and the payment gate",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explained"})

      html = render_click(view, "select_explained_tab", %{"tab" => "browser"})

      # The three-surfaces diagram and its load-bearing labels.
      assert html =~ "YOUR LIVE TAB"
      assert html =~ "SANDBOX TAB"
      assert html =~ "AGENT WINDOW"

      # The five cycles.
      assert html =~ "Read over my shoulder"
      assert html =~ "Do the clicking"
      assert html =~ "A fresh tab that forgets"
      assert html =~ "Turn a routine into a check"
      assert html =~ "The long errand — Agent Mode"

      # The posture the closeout roadmap owns: stated, verbatim enough to find.
      # Decided 08-03 — the agent may now file the receipt, but still never pays,
      # and the tutorial must say which of the two of you confirmed.
      assert html =~ "The agent never pays and never holds a card."
      refute html =~ "cannot confirm a purchase"
      assert html =~ "agent_run_confirm_purchase"
      assert html =~ "which of you said so"
      assert html =~ "Ordinary reads do not each create a feed"
      refute html =~ "every read and every click lands"

      # Same contract as the other tutorials: every named command must exist.
      for cmd <- ~w(browser_current browser_read browser_capture_page
                    browser_screenshot browser_find_elements browser_click
                    browser_fill browser_open_tab browser_wait browser_extract
                    browser_flow browser_check_save browser_check_run
                    browser_check_list browser_control_probe
                    agent_run_start agent_run_navigate agent_run_act
                    agent_run_cart agent_run_resume agent_run_finish
                    agent_run_stop) do
        assert html =~ "<code>#{cmd}</code>"

        assert BusterClaw.Commands.command_type(cmd) != nil,
               "tutorial names #{cmd}, which is not in the command catalog"
      end

      refute html =~ "Tutorial in the works"
    end

    # The Trading tutorial left Explained on 08-08 with the surface it taught.

    test "an unknown Explained sub-tab key is refused, not crashed on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "select_home_tab", %{"tab" => "explained"})

      # The rail's whitelist is ExplainedPanel.tab_keys/0; a forged key leaves the
      # current sub-tab in place.
      render_click(view, "select_explained_tab", %{"tab" => "../../etc"})

      assert has_element?(
               view,
               "#home-explained button[phx-value-tab='intro'][aria-selected='true']"
             )
    end

    test "the Explained sub-tab selection survives a glance at Chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # The assign lives in StatusLive, not the `:if`-discarded panel — so an
      # open tutorial must still be open after a round-trip through Chat.
      render_click(view, "select_home_tab", %{"tab" => "explained"})
      render_click(view, "select_explained_tab", %{"tab" => "browser"})
      render_click(view, "select_home_tab", %{"tab" => "chat"})
      assert has_element?(view, "#workbench-pane-explained:not([hidden])")

      render_click(view, "select_home_tab", %{"tab" => "explained"})

      assert has_element?(
               view,
               "#home-explained button[phx-value-tab='browser'][aria-selected='true']"
             )
    end
  end
end
