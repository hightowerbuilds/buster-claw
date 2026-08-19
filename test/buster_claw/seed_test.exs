defmodule BusterClaw.SeedTest do
  @moduledoc """
  `BusterClaw.Seed` is the mechanism that lets a shipped default improve without
  destroying an operator's edits (`UPDATE_ROADMAP` `G-44`).

  Two kinds of test live here and they defend different things:

    * the **mechanism** tests — four outcomes, and the asymmetry that makes the
      whole thing safe;
    * the **manifest** test — a review-forcing snapshot pinning each current
      digest, without which the version lists in `BusterClaw.Jobs` rot silently.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.{Jobs, Seed}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_seed_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp path(root), do: Path.join(root, "seeded.md")

  describe "the four outcomes" do
    test "a missing file is created", %{root: root} do
      p = path(root)

      assert {:ok, :created} = Seed.write(p, "v2", [Seed.digest("v1"), Seed.digest("v2")])
      assert File.read!(p) == "v2"
    end

    test "a file already holding the current default is left alone", %{root: root} do
      p = path(root)
      File.write!(p, "v2")

      assert {:ok, :current} = Seed.write(p, "v2", [Seed.digest("v1"), Seed.digest("v2")])
      assert File.read!(p) == "v2"
    end

    test "a file still holding an EARLIER shipped default is upgraded", %{root: root} do
      p = path(root)
      File.write!(p, "v1")

      assert {:ok, :upgraded} = Seed.write(p, "v2", [Seed.digest("v1"), Seed.digest("v2")])
      assert File.read!(p) == "v2"
    end

    test "a file the operator has edited is never touched", %{root: root} do
      p = path(root)
      File.write!(p, "v1 plus my own notes")

      assert {:ok, :kept} = Seed.write(p, "v2", [Seed.digest("v1"), Seed.digest("v2")])
      assert File.read!(p) == "v1 plus my own notes"
    end
  end

  describe "the safety asymmetry" do
    # The whole design rests on this: an unrecognised digest is ALWAYS the
    # operator's. So a forgotten version entry costs an upgrade that did not
    # happen, never a file that got destroyed. Reintroducing the defect means
    # dropping a digest from the list, so that is what this does.
    test "a shipped version missing from the list is treated as the operator's, not overwritten",
         %{root: root} do
      p = path(root)
      File.write!(p, "v1")

      # `v1` really was ours — but the list has forgotten it.
      assert {:ok, :kept} = Seed.write(p, "v2", [Seed.digest("v2")])
      assert File.read!(p) == "v1", "a forgotten version must cost an upgrade, never the file"
    end

    test "an empty version list can only create, never overwrite", %{root: root} do
      p = path(root)
      File.write!(p, "anything at all")

      assert {:ok, :kept} = Seed.write(p, "v2", [])
      assert File.read!(p) == "anything at all"
    end
  end

  describe "failure is best-effort, because this runs at boot" do
    test "an unreadable path reports :error rather than raising", %{root: root} do
      # A directory where a file is expected: File.read/1 returns {:error, :eisdir}.
      p = path(root)
      File.mkdir_p!(p)

      assert {:ok, :error} = Seed.write(p, "v2", [Seed.digest("v2")])
    end
  end

  describe "the Jobs manifest" do
    # A REVIEW-FORCING SNAPSHOT, not scenery. Editing any `default_*` in
    # `BusterClaw.Jobs` without appending its new digest fails here, with the
    # digest to add in the message.
    #
    # It has to exist because the failure it guards is otherwise SILENT and in
    # the safe direction: a stale list does not corrupt anything, it just means
    # every install quietly looks "edited" and stops upgrading forever. Nothing
    # else in the build would ever notice.
    test "every current default's digest is the LAST entry in its version list" do
      for %{name: name, content: content, versions: versions} <- Jobs.seed_manifest() do
        digest = Seed.digest(content)

        assert List.last(versions) == digest, """
        The current default for #{name} is not the last entry in its version list.

        If you edited it, APPEND this digest to the matching @*_versions list in
        lib/buster_claw/jobs.ex — do not replace or reorder the existing entries,
        they are what identify the installs still holding them:

            "#{digest}"
        """
      end
    end

    test "no version is listed twice, which would mean a reverted edit lost its history" do
      for %{name: name, versions: versions} <- Jobs.seed_manifest() do
        assert versions == Enum.uniq(versions), "#{name} lists a digest more than once"
      end
    end

    test "the manifest is not empty, and covers every seeded job file" do
      names = Jobs.seed_manifest() |> Enum.map(& &1.name) |> Enum.sort()

      assert names == ["README.md", "mail-triage.md", "sms-triage.md", "voicemail-triage.md"]
    end
  end

  describe "the case that forced this to exist" do
    # The pre-08-18 sms-triage brief told the agent to run `sms_send`, a command
    # deleted that day. Every workspace created before then holds it. Under the
    # old create-only seeding it would have held it forever, and the agent would
    # have kept reaching for a verb the catalog no longer has.
    @sms_triage_before_intake_only "d3aa96c6afe7839c8cf4b03a031febdcd8980cafc7e2ac95bf82bc29c2e78088"

    test "the pre-intake-only sms-triage brief is still recognised as ours" do
      %{versions: versions} =
        Jobs.seed_manifest() |> Enum.find(&(&1.name == "sms-triage.md"))

      assert @sms_triage_before_intake_only in versions, """
      The digest of the sms-triage brief that named `sms_send` has been dropped
      from @sms_triage_versions. Every workspace created before 08-18 holds that
      file, and without this entry none of them will ever be upgraded off it.
      """
    end

    test "the current sms-triage brief does not name a command that no longer exists" do
      %{content: content} = Jobs.seed_manifest() |> Enum.find(&(&1.name == "sms-triage.md"))

      refute content =~ "sms_send"
      refute content =~ "phone_call"
    end

    test "no seeded job brief names a command the catalog does not carry" do
      # The runtime twin of scripts/check_docs_drift.sh, over the text actually
      # written into an operator's workspace. `check_docs_drift.sh` scans
      # README/docs/user-guide and would never have caught this one.
      known = MapSet.new(BusterClaw.Commands.Catalog.entries(), & &1.name)

      for %{name: name, content: content} <- Jobs.seed_manifest(),
          [_, verb] <- Regex.scan(~r{\./buster-claw run ([a-z0-9_]+)}, content) do
        assert MapSet.member?(known, verb),
               "#{name} tells the agent to run `#{verb}`, which is not in the command catalog"
      end
    end
  end
end
