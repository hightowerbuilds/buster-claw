defmodule BusterClaw.WorkspaceTest do
  # async: false — the ensure/0 tests point the global :workspace_root at a tmp
  # dir. Run async, they hand their temp workspace to every other test reading
  # that env concurrently (it took out SoundStudio and BrowserSuggest first try).
  use ExUnit.Case, async: false

  alias BusterClaw.Workspace

  @lib Path.expand("../../lib", __DIR__)

  describe "the registry" do
    test "every entry is fully declared" do
      for entry <- Workspace.entries() do
        assert is_binary(entry.name) and entry.name != ""
        assert entry.kind in [:dir, :file]
        assert entry.tier in [:core, :on_demand, :transient, :deprecated]

        assert entry.seed == nil or match?({m, f} when is_atom(m) and is_atom(f), entry.seed)

        assert is_binary(entry.note) and entry.note != "",
               "#{entry.name} needs a note saying what it holds, in the user's terms"
      end
    end

    test "names are unique" do
      names = Workspace.names()
      assert length(names) == length(Enum.uniq(names))
    end

    test "path/1 refuses an undeclared entry" do
      assert_raise ArgumentError, ~r/not a declared workspace entry/, fn ->
        Workspace.path("some-new-idea")
      end
    end

    test "path/1 resolves a declared entry under the workspace root" do
      assert Workspace.path("skills") ==
               BusterClaw.Library.Artifact.workspace_path("skills")
    end

    # THE NAME-RECLAMATION GUARD. Twice a directory was declared `:deprecated`,
    # then had its name taken over by a new live feature, and the stale entry
    # was left behind: `sources/` (caught 08-03) and `notes/` (caught 08-09,
    # after the Notes vault shipped into a name the registry still called an
    # orphan "superseded by journal/").
    #
    # Neither was destructive — `sweep_deprecated/0` refuses a non-empty
    # directory — but both meant the sweeper deleted a live feature's folder on
    # every boot where it happened to be empty, and both survived a human
    # reading the file, because the entry reads perfectly well in isolation.
    #
    # The `owner:` field is no use here — it records who owned the directory
    # historically, so `analysis/` legitimately still names a live module. The
    # signal that a name has been RECLAIMED is that live code reaches for the
    # path, which is precisely what the layout guard below already walks lib/ to
    # compute. Deprecated means nothing builds it any more; if something does,
    # the tier is wrong.
    test "no deprecated entry is still reached by live code" do
      reached = source_files() |> Enum.flat_map(&referenced_entries/1) |> Map.new()

      reclaimed =
        Workspace.entries(:deprecated)
        # Directories only, mirroring `sweep_deprecated/0`'s own filter — a
        # deprecated *file* is never swept, and the one we have (`MANUAL.html`)
        # is referenced by `Pages.ensure/0` for the express purpose of deleting
        # it, which is the opposite of a reclaimed name.
        |> Enum.filter(&(&1.kind == :dir and Map.has_key?(reached, &1.name)))
        |> Enum.map(&{&1.name, Map.fetch!(reached, &1.name)})

      assert reclaimed == [], """
      These entries are declared :deprecated but live code still reaches for them:

      #{Enum.map_join(reclaimed, "\n", fn {name, file} -> "    #{name}  (#{file})" end)}

      A deprecated entry is swept on boot whenever it is empty. If a feature has
      taken the name over, move it out of the deprecated block and give it a real
      tier, owner and seed — otherwise the sweeper deletes a live folder every
      time the operator happens to leave it empty.

      This has happened twice: `sources/` (08-03) and `notes/` (08-09).
      """
    end

    test "a deprecated entry never seeds itself on boot" do
      for entry <- Workspace.entries(:deprecated) do
        assert entry.seed == nil,
               "#{entry.name}/ is :deprecated but still seeds itself on boot"
      end
    end
  end

  # --- the lockstep guard --------------------------------------------------
  #
  # The workspace grew to twenty top-level entries because each feature added its
  # own directory and no list described the whole. This walks lib/ and fails if
  # any module reaches for a top-level workspace path the registry doesn't
  # declare — the same idiom as SettingsTabsTest and the Rust acl_lockstep suite.
  #
  # Only *statically resolvable* paths are checked: a literal, a list whose head
  # is a literal, or a module attribute defined in the same file. Calls whose
  # argument is a variable (`workspace_path(rel)`) carry a path from stored data
  # and are fenced by their own containment guards; there is nothing to compare
  # against here.

  describe "workspace layout guard" do
    test "no module writes to an undeclared top-level workspace entry" do
      undeclared =
        source_files()
        |> Enum.flat_map(&referenced_entries/1)
        |> Enum.reject(fn {name, _file} -> Workspace.declared?(name) end)
        |> Enum.uniq()

      assert undeclared == [], """
      These top-level workspace entries are used in lib/ but not declared in
      BusterClaw.Workspace:

      #{Enum.map_join(undeclared, "\n", fn {name, file} -> "    #{name}  (#{file})" end)}

      That list is the only description of the workspace layout that exists — if
      an entry isn't in it, nothing can tell a user (or us) what the folder is
      supposed to contain. Add it with a tier and a note, or stop writing to it.
      """
    end

    test "the guard actually resolves the paths it claims to check" do
      # A guard that silently resolves nothing would pass forever. Assert it
      # finds the entries we know are reached via each supported shape:
      # a bare literal, a list head, and a module attribute.
      found = source_files() |> Enum.flat_map(&referenced_entries/1) |> MapSet.new(&elem(&1, 0))

      # `mcp` was in this list until 08-08; it was Trading's MCP config dir and
      # nothing references it now. Its shape (a list head) is still covered by
      # `memory` and `browser-control`, so no regex goes unexercised.
      for name <- ["journal", "memory", "browser-control", "skills", "sounds"] do
        assert name in found, "the guard failed to resolve #{name} — its regexes have drifted"
      end
    end
  end

  defp source_files do
    Path.wildcard(Path.join(@lib, "**/*.ex"))
  end

  # Top-level workspace entries a file statically reaches for, as {name, file}.
  defp referenced_entries(file) do
    src = File.read!(file)
    rel = Path.relative_to(file, Path.dirname(@lib))
    attrs = attribute_values(src)

    literals =
      ~r/workspace_path\(\s*"([^"]+)"/
      |> Regex.scan(src)
      |> Enum.map(&Enum.at(&1, 1))

    list_heads =
      ~r/workspace_path\(\s*\[\s*"([^"]+)"/
      |> Regex.scan(src)
      |> Enum.map(&Enum.at(&1, 1))

    via_attrs =
      ~r/workspace_path\(\s*@([a-z_]+)\s*\)/
      |> Regex.scan(src)
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.flat_map(&List.wrap(Map.get(attrs, &1)))

    (literals ++ list_heads ++ via_attrs)
    |> Enum.map(&top_segment/1)
    |> Enum.uniq()
    |> Enum.map(&{&1, rel})
  end

  # Module attributes defined as a literal, or as a Path.join of literals — take
  # the first string either way, since only the top-level segment matters
  # (`@subdir Path.join("studio", "tracks")` lives under the declared `studio`).
  defp attribute_values(src) do
    ~r/^\s*@([a-z_]+)\s+(?:Path\.join\()?"([^"]+)"/m
    |> Regex.scan(src)
    |> Map.new(fn [_, name, value] -> {name, value} end)
  end

  defp top_segment(path), do: path |> Path.split() |> List.first()

  # --- Phase 0's headline fix ----------------------------------------------

  describe "ensure/0" do
    setup do
      root = Path.join(System.tmp_dir!(), "bc_ws_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      prev_ws = Application.get_env(:buster_claw, :workspace_root)
      prev_lib = Application.get_env(:buster_claw, :library_root)
      Application.put_env(:buster_claw, :workspace_root, root)
      Application.put_env(:buster_claw, :library_root, Path.join(root, "library"))

      # `WorkspaceCLI.ensure/0` writes the `buster-claw` launcher only if it can
      # find a CLI to point at, and its last fallback is `./buster-claw` in the
      # cwd — a GITIGNORED escript build artifact. So these tests passed on a
      # machine that had run `mix escript.build` and failed on a clean clone,
      # which is the worst way for an assertion to be environment-dependent: it
      # is green for whoever wrote it.
      #
      # Point the documented env seam at a real file instead. The launcher path
      # is now decided by the test rather than by whether someone happened to
      # build an escript, and `ensure/0` is still asserted to write it.
      # Outside `root`: anything inside it would be an undeclared entry and trip
      # the registry guard two tests down.
      cli = root <> "-cli"
      File.write!(cli, "#!/bin/sh\nexit 0\n")
      File.chmod!(cli, 0o755)
      prev_cli = System.get_env("BUSTER_CLAW_CLI_PATH")
      System.put_env("BUSTER_CLAW_CLI_PATH", cli)

      on_exit(fn ->
        Application.put_env(:buster_claw, :workspace_root, prev_ws)
        Application.put_env(:buster_claw, :library_root, prev_lib)

        if prev_cli,
          do: System.put_env("BUSTER_CLAW_CLI_PATH", prev_cli),
          else: System.delete_env("BUSTER_CLAW_CLI_PATH")

        File.rm_rf(root)
        File.rm_rf(cli)
      end)

      {:ok, root: root}
    end

    test "scaffolds a workspace and is idempotent", %{root: root} do
      assert :ok = Workspace.ensure()
      first = root |> File.ls!() |> Enum.sort()

      refute first == []
      assert ".buster-claw" in first
      assert "skills" in first
      assert "jobs" in first
      assert "README.md" in first
      # The machine file lives out of the user's eyeline, not at the root.
      refute "INTRODUCTION.md" in first
      assert File.exists?(Path.join(root, ".buster-claw/INTRODUCTION.md"))

      assert :ok = Workspace.ensure()
      assert root |> File.ls!() |> Enum.sort() == first
    end

    # The whole point of Phase 2: installing the app must not lay down a folder
    # for every feature the user has not touched yet.
    test "creates no on-demand entry", %{root: root} do
      :ok = Workspace.ensure()
      present = File.ls!(root)

      eager =
        Workspace.entries(:on_demand)
        |> Enum.map(& &1.name)
        |> Enum.filter(&(&1 in present))

      assert eager == [],
             "ensure/0 eagerly created on-demand entries: #{inspect(eager)}"
    end

    test "every entry it does create holds something", %{root: root} do
      :ok = Workspace.ensure()

      empty =
        root
        |> File.ls!()
        |> Enum.map(&{&1, Path.join(root, &1)})
        |> Enum.filter(fn {_name, path} -> File.dir?(path) and File.ls!(path) == [] end)
        |> Enum.map(&elem(&1, 0))

      assert empty == [], "a fresh install left empty directories: #{inspect(empty)}"
    end

    test "ensure_entry/1 materializes an on-demand folder at the point of use", %{root: root} do
      :ok = Workspace.ensure()
      refute "sounds" in File.ls!(root)

      assert :ok = Workspace.ensure_entry("sounds")
      assert "sounds" in File.ls!(root)

      # Idempotent — surfaces call this on every mount.
      assert :ok = Workspace.ensure_entry("sounds")
    end

    test "ensure_entry/1 refuses an undeclared name" do
      assert_raise ArgumentError, ~r/not a declared workspace entry/, fn ->
        Workspace.ensure_entry("nope")
      end
    end

    test "the README lists the layout, generated from the registry", %{root: root} do
      :ok = Workspace.ensure()
      readme = File.read!(Path.join(root, "README.md"))

      for entry <- Workspace.entries(:core) ++ Workspace.entries(:on_demand),
          entry.name != "README.md" do
        assert readme =~ entry.name, "README doesn't mention #{entry.name}"
      end

      # It describes the folder to a person, not the registry to us.
      refute readme =~ ":on_demand"
    end

    test "creates nothing the registry doesn't declare", %{root: root} do
      :ok = Workspace.ensure()

      undeclared = root |> File.ls!() |> Enum.reject(&Workspace.declared?/1)

      assert undeclared == [],
             "ensure/0 created undeclared entries: #{inspect(undeclared)}"
    end

    # The bug Phase 0 exists to kill: set_workspace_root/1 used to run a
    # hand-picked subset of four seeders, so moving your workspace produced a
    # folder missing its jobs, skills and policy template until the next restart.
    # Both paths now call this same function, so one test covers both.
    test "produces the layout a fresh boot would", %{root: root} do
      :ok = Workspace.ensure()
      moved = root |> File.ls!() |> Enum.sort()

      for entry <- ~w(.buster-claw buster-claw jobs skills memory) do
        assert entry in moved, "a moved workspace is missing #{entry}"
      end
    end

    # Phase 3A: feature-named entries became content-named, and the machine
    # bookkeeping moved into `.buster-claw/`. An existing install's files must
    # arrive at the new names with nothing lost.
    test "relocates the pre-rename layout: jobs, backgrounds, dispatch", %{root: root} do
      File.mkdir_p!(Path.join(root, "job-descriptions"))
      File.write!(Path.join(root, "job-descriptions/custom.md"), "# Custom\n")
      File.mkdir_p!(Path.join(root, "appearance"))
      File.write!(Path.join(root, "appearance/background-1.png"), "bytes")
      File.mkdir_p!(Path.join(root, "shift/2026-07-31"))
      File.write!(Path.join(root, "shift/Dispatch.md"), "stale fridge")
      File.write!(Path.join(root, "shift/2026-07-31/Dispatch.jsonl"), ~s({"event":"queued"}\n))
      File.write!(Path.join(root, "INTRODUCTION.md"), "stale machine copy")

      assert :ok = Workspace.ensure()
      listing = File.ls!(root)

      refute "job-descriptions" in listing
      refute "appearance" in listing
      refute "shift" in listing

      # User content arrived intact at the new names.
      assert File.read!(Path.join(root, "jobs/custom.md")) == "# Custom\n"

      # Two hops in ONE pass: `appearance/` → `backgrounds/` →
      # `pockets/backgrounds/`. @relocations is ordered, so an install that
      # skipped a release crosses the whole chain on the next launch rather than
      # stalling at an intermediate name nothing owns any more.
      assert File.read!(Path.join(root, "pockets/backgrounds/background-1.png")) == "bytes"
      refute "backgrounds" in listing

      assert File.read!(Path.join(root, ".buster-claw/dispatch/2026-07-31/Dispatch.jsonl")) ==
               ~s({"event":"queued"}\n)

      # Machine-regenerated files are deleted at the old home, not carried along.
      refute File.exists?(Path.join(root, "INTRODUCTION.md"))
      refute File.exists?(Path.join(root, ".buster-claw/dispatch/Dispatch.md"))
    end

    test "audio is one folder: no top-level music/ or studio/", %{root: root} do
      :ok = Workspace.ensure()
      BusterClaw.Music.ensure()
      BusterClaw.Notifications.SoundStudio.ensure()

      listing = File.ls!(root)
      refute "music" in listing
      refute "studio" in listing
      assert "sounds" in listing

      assert File.dir?(Path.join([root, "sounds", "music"]))
      assert File.dir?(Path.join([root, "sounds", "studio"]))
    end

    test "chimes and the music library don't see each other", %{root: root} do
      BusterClaw.Music.ensure()
      File.write!(Path.join([root, "sounds", "chime.wav"]), "chime")
      File.write!(Path.join([root, "sounds", "music", "song.mp3"]), "song")

      # Sound.list/0 filters on File.regular?, so the nested dirs stay out of it.
      assert BusterClaw.Notifications.Sound.list() == ["chime.wav"]
      assert BusterClaw.Music.list() == ["song.mp3"]
    end

    test "migrates an existing install's music/ and studio/ into sounds/", %{root: root} do
      File.mkdir_p!(Path.join(root, "music"))
      File.mkdir_p!(Path.join(root, "studio"))
      File.write!(Path.join([root, "music", "song.mp3"]), "audio")
      File.write!(Path.join([root, "studio", "take.wav"]), "take")

      :ok = Workspace.ensure()

      refute "music" in File.ls!(root)
      refute "studio" in File.ls!(root)
      assert File.read!(Path.join([root, "sounds", "music", "song.mp3"])) == "audio"
      assert File.read!(Path.join([root, "sounds", "studio", "take.wav"])) == "take"
    end

    test "the migration merges rather than clobbers when both exist", %{root: root} do
      File.mkdir_p!(Path.join(root, "music"))
      File.mkdir_p!(Path.join([root, "sounds", "music"]))
      File.write!(Path.join([root, "music", "old.mp3"]), "from the old folder")
      File.write!(Path.join([root, "music", "clash.mp3"]), "old copy")
      File.write!(Path.join([root, "sounds", "music", "clash.mp3"]), "new copy")

      :ok = Workspace.ensure()

      # The non-colliding file moved...
      assert File.read!(Path.join([root, "sounds", "music", "old.mp3"])) == "from the old folder"
      # ...the collision was left alone, both copies intact.
      assert File.read!(Path.join([root, "sounds", "music", "clash.mp3"])) == "new copy"
      assert File.read!(Path.join([root, "music", "clash.mp3"])) == "old copy"
    end

    test "the migration is idempotent and a no-op on a fresh install", %{root: root} do
      :ok = Workspace.ensure()
      first = root |> File.ls!() |> Enum.sort()
      :ok = Workspace.ensure()

      assert root |> File.ls!() |> Enum.sort() == first
    end

    test "sweeps empty deprecated directories away", %{root: root} do
      # `notes` was one of these until 08-09, when it turned out the Notes vault
      # had reclaimed the name — see the reclamation test below.
      for dead <- ~w(analysis extensions), do: File.mkdir_p!(Path.join(root, dead))

      :ok = Workspace.ensure()

      listing = File.ls!(root)
      refute "analysis" in listing
      refute "extensions" in listing
    end

    # `sources/` was deprecated (a file-export feature nobody built) until 08-03,
    # when the source registry reclaimed the name for operator overrides. The
    # sweep must NOT touch it any more: an operator who empties their override
    # folder would otherwise find it deleted, and the next override they write
    # would land in a directory the app had decided was rubbish.
    test "the reclaimed sources/ directory survives the sweep", %{root: root} do
      File.mkdir_p!(Path.join(root, "sources"))

      :ok = Workspace.ensure()

      assert "sources" in File.ls!(root)
      refute "sources" in Workspace.sweep_deprecated()
    end

    # The same story, one folder and five months later: `notes/` was an orphan
    # "superseded by journal/" until the Notes vault shipped on 08-08 and took
    # the name. The registry went on calling it deprecated until 08-09, so an
    # operator with an empty vault had the directory removed on every boot.
    # Nothing was lost — the sweeper refuses a non-empty directory, and Notes
    # re-created it on next touch — but an empty vault is the NEW operator's
    # state, which is the worst audience for a folder that keeps vanishing.
    test "the reclaimed notes/ vault survives the sweep", %{root: root} do
      File.mkdir_p!(Path.join(root, "notes"))

      :ok = Workspace.ensure()

      assert "notes" in File.ls!(root)
      refute "notes" in Workspace.sweep_deprecated()
    end

    # Decluttering never outranks not destroying someone's files.
    test "never removes a deprecated directory that holds anything", %{root: root} do
      File.mkdir_p!(Path.join(root, "analysis"))
      File.write!(Path.join([root, "analysis", "mine.md"]), "something I wrote")

      :ok = Workspace.ensure()

      assert "analysis" in File.ls!(root)
      assert File.read!(Path.join([root, "analysis", "mine.md"])) == "something I wrote"
    end

    test "sweep_deprecated/0 reports what it removed", %{root: root} do
      File.mkdir_p!(Path.join(root, "analysis"))
      File.mkdir_p!(Path.join(root, "extensions"))
      File.write!(Path.join([root, "extensions", "keep.md"]), "x")

      removed = Workspace.sweep_deprecated()

      assert Enum.sort(removed) == ["analysis"]
      assert Workspace.sweep_deprecated() == []
    end

    test "a fresh workspace grows no deprecated directories at all", %{root: root} do
      :ok = Workspace.ensure()

      deprecated = Enum.map(Workspace.entries(:deprecated), & &1.name)
      present = File.ls!(root)

      assert Enum.filter(deprecated, &(&1 in present)) == []
    end
  end
end
