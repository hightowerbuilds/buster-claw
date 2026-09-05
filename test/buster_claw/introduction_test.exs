defmodule BusterClaw.IntroductionTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Appearance
  alias BusterClaw.Commands
  alias BusterClaw.Introduction

  setup do
    root =
      Path.join(System.tmp_dir!(), "buster-claw-intro-#{System.unique_integer([:positive])}")

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      if prev, do: Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "markdown explains the app, the summary convention, and lists commands" do
    md = Introduction.markdown()

    assert md =~ "Buster Claw — Operating Guide"
    assert md =~ "journal_append"
    assert md =~ "library/"
    # Command surface, grouped by tier, with real catalog entries.
    assert md =~ "Safe (agent-callable)"
    assert md =~ "Restricted (require confirmation)"
    assert md =~ "`document_list`"
    assert md =~ "`document_save`"
  end

  # The introduction went stale for a day on exactly this: it said backgrounds
  # were "chosen in Settings → Appearance" and that the model "can never force
  # one onto their screen", while `background_set` had shipped and did precisely
  # that. The command list below the prose is generated from the catalog, so the
  # verb was already listed — and the prose contradicting it is worse than a
  # missing entry, because prose is what the model believes.
  test "the model is told about every appearance verb the catalog gives it" do
    md = Introduction.markdown()

    verbs =
      Commands.list_commands()
      |> Enum.map(& &1.name)
      |> Enum.filter(&String.starts_with?(&1, "background_"))

    assert verbs != [], "no background verbs — did they move? this guard is now vacuous"

    # Asserted against the PROSE, not the whole document. The generated command
    # surface at the end lists every verb in the catalog, so `md =~ verb` is
    # true no matter what the prose says — which made the first version of this
    # guard pass with the section deleted. Split it off and test the half a
    # human wrote.
    [prose, _generated] = String.split(md, "These are the commands you can run", parts: 2)

    for verb <- verbs do
      assert prose =~ verb,
             "the prose never names #{verb}; a generated table below it is not the same thing"
    end

    # And the prose has to agree with them, not merely coexist. Both halves:
    # it CAN point a surface at a background...
    assert md =~ "Changing a background yourself"
    assert md =~ "terminal" and md =~ "home"

    # ...and it can only apply SOME shaders, which is the refusal it will
    # otherwise hit and read as a bug. Asserted against a whitespace-flattened
    # copy: this prose is hard-wrapped, so a sentence the model reads as one
    # line is not one line in the source, and an assertion that pins the wrap
    # point starts failing on a reflow that changed nothing.
    flat = String.replace(prose, ~r/\s+/, " ")

    # The two tiers of the rule, in the model's own terms. Applying a built-in
    # always works; applying a workspace shader depends on the operator having
    # applied that exact file once themselves.
    assert flat =~ "the five built-ins outright"
    assert flat =~ "applied that exact file themselves in Settings → Appearance"

    # The LIST, rendered, not each word — `veil` and `weather` appear elsewhere
    # in this section, so a per-word loop passed with two of the five deleted.
    applicable = Enum.map_join(Appearance.builtin_shaders(), ", ", &"`#{&1}`")

    assert flat =~ applicable,
           "the prose must name exactly the always-applicable set, in order: #{applicable}"

    # Approval is by CONTENT HASH, so the model editing a shader revokes it.
    # A briefing that taught the exception without this would teach a model to
    # edit an approved file and expect it to keep working.
    assert flat =~ "if you edit the shader the approval is void"

    # The practical consequence for a shader the model just wrote: hand over
    # the name and ask, rather than promise an apply it cannot perform.
    assert flat =~ "tell them the name, and ask them to apply it once"

    # ...and the loop the operator explicitly does NOT want (roadmap VIII.2).
    # Without this the exception reads as an invitation to iterate.
    assert flat =~ "do not plan on tweak-look-tweak"

    # The claim that was wrong must not come back in any form.
    refute md =~ "can never force one onto their screen"
    refute md =~ "only when the user selects it"

    # Nor may the rule that REPLACED it, which was true for one day: the
    # absolute refusal is now the unapproved case only, and prose stating it
    # flatly would send the model at a wall that is no longer there.
    flat_md = String.replace(md, ~r/\s+/, " ")
    refute flat_md =~ "will not apply a workspace shader at all"
    refute flat_md =~ "whoever wrote it"
  end

  # The briefing went stale twice on 08-15 — it denied a capability that had
  # shipped, and it described two background surfaces when there were three. Both
  # were found by a human reading, which does not scale to 200-odd commands.
  #
  # This is the general form: every FAMILY of commands must be named somewhere a
  # human wrote. It deliberately does not check individual verbs — the generated
  # catalog covers those, and demanding prose for all 206 would be noise that
  # gets suppressed. A family is the unit at which "the model does not know this
  # exists" starts to cost something.
  test "every command family is named in the prose, not just the generated table" do
    md = Introduction.markdown()
    [prose, _generated] = String.split(md, "These are the commands you can run", parts: 2)

    families =
      Commands.list_commands()
      |> Enum.map(& &1.name)
      |> Enum.group_by(fn name -> name |> String.split("_") |> hd() end)

    assert families != %{},
           "no command families — the catalog is empty and this guard is now vacuous"

    # This guard is derived, so a family LEAVING the catalog silently removes its
    # obligation, and that is correct: `sms` went on 08-18 with `sms_send`
    # (PHONE_INTAKE_ROADMAP), and `introduction/` no longer contains "sms_"
    # anywhere. Nothing here passes by accident — there is genuinely no `sms`
    # key to check.
    #
    # But an *absence* is a claim this test cannot make, only a promise it
    # stopped checking — and "the briefing must not advertise a verb the catalog
    # lacks" is the opposite direction from the one this guard runs in. That
    # claim is made by the next test down, in its `else` branch. Deliberately not
    # duplicated here: two guards with different tolerances for the same fact is
    # how one of them ends up wrong.
    missing =
      Enum.reject(families, fn {family, commands} ->
        String.contains?(prose, family <> "_") or
          Enum.any?(commands, &String.contains?(prose, &1))
      end)

    assert missing == [],
           """
           These command families exist and INTRODUCTION.md never mentions them:

             #{Enum.map_join(missing, ", ", &elem(&1, 0))}

           The generated catalog at the end of the document lists every verb, so
           the model can see them — but prose is what it believes, and a family
           with no orientation is one it will not reach for or will misuse. Add a
           row to the table in `introduction/01-orientation.md` and a paragraph
           wherever it belongs.
           """
  end

  # The family guard above catches a capability the briefing never mentions. It
  # cannot catch one the briefing DENIES — `phone_*` was named throughout while a
  # bullet said "there is no outbound calling", which is the shape that shipped
  # on 08-15 and had to be corrected. A denial needs its own assertion, tied to
  # the catalog so it cannot outlive the verb.
  #
  # **Both branches are load-bearing, and the `else` is why this test still
  # exists.** As written on 08-15 the body was a bare `if` over
  # `command_type("phone_call")`. `phone_call` and `sms_send` left the catalog on
  # 08-18 (PHONE_INTAKE_ROADMAP) — and a bare `if` would then have gone
  # permanently, silently green, guarding nothing, in a file whose whole subject
  # is prose drifting away from the catalog. That is this repo's recorded failure
  # mode: a collection empties and its guard goes vacuously green.
  #
  # The two directions are different bugs and both are real:
  #   - verb present, briefing denies it → the model never offers a capability it
  #     has (the 08-15 bug);
  #   - verb absent, briefing promises it → the model offers a capability it does
  #     not have, and only finds out mid-task, having already told the operator
  #     it would ring somebody back. That one is worse, and it is the live case.
  test "the briefing agrees with the catalog about outbound, in whichever direction" do
    md = Introduction.markdown()
    [prose, _generated] = String.split(md, "These are the commands you can run", parts: 2)

    # This prose is hard-wrapped, so a sentence the model reads as one line is
    # not one line in the source.
    flat = String.replace(prose, ~r/\s+/, " ")

    if Commands.command_type("phone_call") do
      assert prose =~ "can make phone calls"

      refute prose =~ "There is no outbound calling",
             "phone_call exists; the briefing must not tell the model otherwise"

      # The shape is the surprising part and the model will offer this wrongly
      # without it: the OPERATOR's phone rings first, so a success means a call
      # was created, never that anyone spoke.
      assert prose =~ "rings *the operator's own phone*"
      assert prose =~ "never\n*somebody spoke*" or prose =~ "never *somebody spoke*"

      # The refusal it would otherwise promise and then fail to deliver.
      assert prose =~ "emergency number is not dialable"
    else
      # No dialler in the catalog, so the briefing may not describe one — in any
      # of the shapes the 08-15 version used, since a partial edit that leaves
      # one sentence behind is the likely failure, not a wholesale relapse.
      refute flat =~ "can make phone calls"
      refute flat =~ "phone_call"
      refute flat =~ "rings *the operator's own phone*"
      refute flat =~ "emergency number is not dialable"

      # And it must not promise the OTHER direction of a positive claim: that it
      # will ring anyone back.
      refute flat =~ "call them back"
      refute flat =~ "ring them back"
    end

    if Commands.command_type("sms_send") do
      assert flat =~ "sms_send"
    else
      refute flat =~ "sms_send"
      refute flat =~ "text them back"
      refute flat =~ "reply by text"
    end

    # The absence is not enough on its own. A briefing that simply stops
    # mentioning outbound leaves the model to assume — and it will assume a
    # phone can be answered by phone, because every other phone can. So when
    # neither verb exists the prose has to say so OUT LOUD, and this asserts the
    # positive statement rather than only the absence of the wrong ones.
    intake_only? =
      is_nil(Commands.command_type("phone_call")) and is_nil(Commands.command_type("sms_send"))

    if intake_only? do
      assert flat =~ "It only receives",
             "the briefing must state the absence, not merely omit the capability"

      assert flat =~ "There is no verb that sends a text or places a call"

      # ...and tell it what to do instead, or "you cannot reply" is a dead end
      # rather than an instruction.
      assert flat =~ "you do the work and write it down"
    end
  end

  # The Sketch Pad was deleted on 09-05 — its route, its Studio tab, and six
  # `sketch_*` commands. The briefing carried a whole section teaching the model
  # to call them, which is the worse of the two stale shapes: not a capability it
  # never hears about, but one it OFFERS and only discovers is gone after telling
  # the operator a drawing exists.
  #
  # Both directions, tied to the catalog, for the reason the outbound guard below
  # states at length: a bare `refute` here would be a promise this test stopped
  # checking the moment anyone re-added the verbs.
  test "the briefing agrees with the catalog about drawing" do
    md = Introduction.markdown()
    [prose, _generated] = String.split(md, "These are the commands you can run", parts: 2)
    flat = String.replace(prose, ~r/\s+/, " ")

    if Commands.command_type("sketch_get") do
      assert flat =~ "sketch_get",
             "the sketch verbs are back in the catalog; the briefing must teach them"
    else
      # Naming the family in a *negative* sentence is deliberate and allowed —
      # what may not come back is an instruction to call one.
      refute flat =~ "sketch_list"
      refute flat =~ "sketch_get"
      refute flat =~ "a surface in the Studio"
    end

    # Absence is not enough. The model CAN draw, by a channel that never had a
    # command and was untouched by the deletion, and a briefing that merely
    # stopped mentioning the Pad would leave it believing it cannot.
    #
    # The fence marker is asserted on both sides rather than remembered on one:
    # if `SvgViewer` ever changes what it extracts, the first assertion fails and
    # whoever changes it is standing in front of the prose that teaches it.
    marker = "```svg"
    assert BusterClaw.SvgViewer.guide() =~ marker
    assert flat =~ marker, "the briefing must teach the fence the SVG viewer extracts"

    # Where it works, and the one constraint whose absence fails silently —
    # a viewBox-less SVG is cropped to its top-left corner, not scaled.
    assert flat =~ "Chat tab on Home"
    assert flat =~ "viewBox"
  end

  test "routes web work by consequence, not by convenience" do
    md = Introduction.markdown()

    # The three engines and the rule that separates them. Without this the model
    # reaches for whatever is listed first, which is how a purchase ends up on
    # the ungated path.
    assert md =~ "pick the engine by consequence"
    assert md =~ "if it can spend money or act as the user, it belongs"
    assert md =~ "`web_search`"
    assert md =~ "`browser_*`"
    assert md =~ "`agent_run_*`"

    # The guardrails the model has to work WITH rather than retry against.
    assert md =~ "scope is frozen at start"
    assert md =~ "Payment pages stop the run"
    assert md =~ "ambiguous_text"

    # 08-03: the operator allowed the agent to confirm, so the guide teaches the
    # verb AND the one way it can do damage. The old "you cannot confirm a
    # purchase" line is gone; a stale rule here is worse than none.
    refute md =~ "You cannot confirm a purchase"
    assert md =~ "agent_run_confirm_purchase"
    assert md =~ "the one way this verb can do damage"

    # The 07-25 field-test lesson, in the model's own guide.
    assert md =~ "verify a chosen variant against the cart line"

    # And where the human watches it. Named for the DOCK LABEL ("Browser"), not
    # the route (`/browse`) or the page title ("Browse") — the model repeats this
    # to the operator, who is looking at the dock.
    assert md =~ "Browser tab"
  end

  test "documents the workspace layout, role model, and corrected summary convention" do
    md = Introduction.markdown()

    # Workspace layout covers the real top-level entries, not just library/memory
    # — and only declared ones: no dead scaffolding (`analysis/`, `projects/`),
    # no pre-rename names.
    assert md =~ "`jobs/`"
    assert md =~ "`Dispatch.md`"
    assert md =~ "`notes/`"
    assert md =~ "`journal/`"
    refute md =~ "`analysis/`"
    refute md =~ "`projects/`"
    refute md =~ "job-descriptions"
    refute md =~ "shift/Dispatch.md"

    # The Activity record: one journal document per day, appended through the
    # command surface (NOT hand-written files — the old summary convention).
    assert md =~ "journal_append"
    assert md =~ "journal_read"
    assert md =~ "YYYY-MM-DD.md"
    refute md =~ "mm-dd-yy-summary"

    # ONE activity log, now correctly separated from the user's Notes notebook.
    # The model must never start dumping routine activity into notes/.
    assert md =~ "The Activity record"
    assert md =~ "exactly one activity log"
    assert md =~ "What is NOT the activity log"
    assert md =~ "homepage Activity tab"

    # Notes LEFT Home on 09-05 for the Workspace page's rail; Activity did not.
    # Both halves are asserted, because the failure this catches is the briefing
    # keeping one name after the surface moved and sending the operator to a tab
    # that no longer holds their notebook.
    #
    # The refute is scoped to the PROSE. The generated catalog carries command
    # descriptions written elsewhere (`note_list`'s still says "homepage Notes
    # tab" as of 09-05, in `commands/catalog/library.ex`), and a doc test that
    # fails on another module's string teaches the next person to loosen this
    # guard rather than fix that description.
    [notes_prose, _] = String.split(md, "These are the commands you can run", parts: 2)
    assert notes_prose =~ "Workspace Notes tab is a separate notebook"
    refute notes_prose =~ "homepage Notes tab"
    refute md =~ "daily minutes"
    refute md =~ "dated diary"

    # ...and the near-miss surfaces are named as non-destinations, so the model
    # can't reason its way into writing activity where nobody will read it.
    assert md =~ "activity_report"
    assert md =~ "the Library holds artifacts"
    assert md =~ "Activity holds what happened"

    # The note_* family is taught WITH its boundary, not as a bare capability:
    # giving the model write access to the operator's notebook without the
    # "only when asked" rule is how Notes becomes a second activity log again.
    assert md =~ "note_read"
    assert md =~ "note_save"
    # Flattened: this prose is hard-wrapped, and the earlier version of this
    # assertion pinned the newline between "the" and "operator", so a reflow
    # that changed no words failed it. Same treatment the appearance guard above
    # already gives its hard-wrapped sentences.
    assert String.replace(md, ~r/\s+/, " ") =~ "only when the operator asked for a note"
    assert md =~ "there is no note delete"
    assert md =~ "revision"

    # notesthatfloat.com is a separate product, acknowledged and firewalled off.
    assert md =~ "notesthatfloat.com"
    assert md =~ "not part of Buster Claw"

    # Jobs & the pull queue: points at the jobs roster as the source of truth
    # and describes pulling work from the dispatch queue via the CLI.
    assert md =~ "Jobs & the pull queue"
    assert md =~ "jobs/README.md"
    assert md =~ "dispatch claim"
  end

  # Inverted 09-05, not deleted. The Cmd List editor and both
  # `terminal_command_*` verbs were removed, so the briefing must now tell the
  # model the OPPOSITE — and a model that offers to edit a list it cannot edit
  # wastes the operator's turn on a refusal. Asserted as an absence for the same
  # reason the Sketch Pad's was: the failure mode is prose outliving its feature.
  test "tells the model the terminal command list is read-only, and points at skills" do
    md = Introduction.markdown()

    refute md =~ "terminal_command_list"
    refute md =~ "terminal_command_set"
    refute md =~ "Editing the terminal Cmd List"

    assert md =~ "read-only"
    assert md =~ "Skills are how new capability gets added"

    # The roles it still lists are real, and the flyout still exists.
    assert md =~ "**prompts**"
  end

  # The trading section left the agent's guide on 08-08 with the stack it
  # described.

  test "install! writes INTRODUCTION.md into the machine-files dir", %{root: root} do
    assert {:ok, path} = Introduction.install!()
    assert path == Path.join(root, ".buster-claw/INTRODUCTION.md")
    assert File.exists?(path)
    assert File.read!(path) =~ "Operating Guide"
  end

  test "install! does not rewrite an already-identical file", %{root: _root} do
    assert {:ok, path} = Introduction.install!()
    mtime = File.stat!(path, time: :posix).mtime

    # A second install with unchanged content must skip the write (mtime stable).
    assert {:ok, ^path} = Introduction.install!()
    assert File.stat!(path, time: :posix).mtime == mtime

    # A changed on-disk file is overwritten back to the generated content.
    File.write!(path, "STALE")
    assert {:ok, ^path} = Introduction.install!()
    assert File.read!(path) =~ "Operating Guide"
  end

  test "read returns the installed file, or generates when absent", %{root: root} do
    # Absent → generated fallback.
    assert Introduction.read() =~ "Operating Guide"

    # Installed → reads the file (here, a sentinel we wrote ourselves).
    File.mkdir_p!(Path.join(root, ".buster-claw"))
    File.write!(Path.join(root, ".buster-claw/INTRODUCTION.md"), "CUSTOM GUIDE")
    assert Introduction.read() == "CUSTOM GUIDE"
  end
end
