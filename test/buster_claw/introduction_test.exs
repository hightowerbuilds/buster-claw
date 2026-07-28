defmodule BusterClaw.IntroductionTest do
  use ExUnit.Case, async: false

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
    assert md =~ "You cannot confirm a purchase"
    assert md =~ "ambiguous_text"

    # The 07-25 field-test lesson, in the model's own guide.
    assert md =~ "verify a chosen variant against the cart line"

    # And where the human watches it.
    assert md =~ "Browse tab"
  end

  test "documents the workspace layout, role model, and corrected summary convention" do
    md = Introduction.markdown()

    # Workspace layout covers the real top-level folders, not just library/memory.
    assert md =~ "`job-descriptions/`"
    assert md =~ "`analysis/`"
    assert md =~ "`shift/`"
    assert md =~ "`journal/`"

    # The Notes record: one journal document per day, appended through the command
    # surface (NOT hand-written files — the old mm-dd-yy-summary/ convention).
    assert md =~ "journal_append"
    assert md =~ "journal_read"
    assert md =~ "YYYY-MM-DD.md"
    refute md =~ "mm-dd-yy-summary"

    # ONE activity log. The whole point of the Notes-record consolidation: the
    # doc must name a single destination and must not reintroduce the competing
    # vocabulary ("minutes"/"diary"/"daily summary") that made it read as three.
    assert md =~ "The Notes record"
    assert md =~ "exactly one activity log"
    assert md =~ "What is NOT the activity log"
    refute md =~ "daily minutes"
    refute md =~ "dated diary"

    # ...and the near-miss surfaces are named as non-destinations, so the model
    # can't reason its way into writing activity where nobody will read it.
    assert md =~ "activity_report"
    assert md =~ "the Library holds artifacts"

    # notesthatfloat.com is a separate product, acknowledged and firewalled off.
    assert md =~ "notesthatfloat.com"
    assert md =~ "not part of Buster Claw"

    # Jobs & the pull queue: points at the job-descriptions roster as the source
    # of truth and describes pulling work from the dispatch queue via the CLI.
    assert md =~ "Jobs & the pull queue"
    assert md =~ "job-descriptions/README.md"
    assert md =~ "shift/Dispatch.md"
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

  test "install! writes INTRODUCTION.md into the workspace root", %{root: root} do
    assert {:ok, path} = Introduction.install!()
    assert path == Path.join(root, "INTRODUCTION.md")
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
    File.mkdir_p!(root)
    File.write!(Path.join(root, "INTRODUCTION.md"), "CUSTOM GUIDE")
    assert Introduction.read() == "CUSTOM GUIDE"
  end
end
