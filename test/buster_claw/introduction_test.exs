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

    # ...and it CANNOT apply a workspace shader, which is the refusal it will
    # otherwise hit and read as a bug. Asserted as the RULE rather than as
    # "one you wrote yourself" — the first version of this prose said that, and
    # it was wrong in the direction that costs a run: `check_shader/2` tests
    # membership of `builtin_shaders/0`, so a shader the OPERATOR wrote is
    # refused too, and prose implying otherwise sends the model at a wall.
    assert prose =~ "only the five\nbuilt-ins" or prose =~ "only the five built-ins"

    # The LIST, rendered, not each word — `veil` and `weather` appear elsewhere
    # in this section, so a per-word loop passed with two of the five deleted.
    applicable = Enum.map_join(Appearance.builtin_shaders(), ", ", &"`#{&1}`")

    assert prose =~ applicable,
           "the prose must name exactly the applicable set, in order: #{applicable}"

    assert prose =~ "whoever wrote it"

    # The claim that was wrong must not come back in any form.
    refute md =~ "can never force one onto their screen"
    refute md =~ "only when the user selects it"
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

    # And where the human watches it.
    assert md =~ "Browse tab"
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
    assert md =~ "homepage Notes tab is a separate notebook"
    refute md =~ "homepage Notes tab.**"
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
    assert md =~ "only when the\noperator asked for a note"
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

  test "documents editing the terminal Cmd List (roles, prompts, the two commands)" do
    md = Introduction.markdown()

    assert md =~ "Editing the terminal Cmd List"
    assert md =~ "`terminal_command_list`"
    assert md =~ "`terminal_command_set`"
    # Names the editable prompts role and the protected safety surface.
    assert md =~ "**prompts**"
    assert md =~ "protected and refused"
    assert md =~ "`mailman`"
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
