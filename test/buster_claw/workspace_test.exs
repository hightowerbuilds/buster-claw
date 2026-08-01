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

      for name <- ["journal", "memory", "mcp", "browser-control", "skills", "sounds"] do
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

      on_exit(fn ->
        Application.put_env(:buster_claw, :workspace_root, prev_ws)
        Application.put_env(:buster_claw, :library_root, prev_lib)
        File.rm_rf(root)
      end)

      {:ok, root: root}
    end

    test "scaffolds a workspace and is idempotent", %{root: root} do
      assert :ok = Workspace.ensure()
      first = root |> File.ls!() |> Enum.sort()

      refute first == []
      assert "INTRODUCTION.md" in first
      assert "skills" in first
      assert "job-descriptions" in first
      assert "README.md" in first

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

      for entry <- ~w(INTRODUCTION.md buster-claw job-descriptions skills memory) do
        assert entry in moved, "a moved workspace is missing #{entry}"
      end
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
      for dead <- ~w(sources analysis notes), do: File.mkdir_p!(Path.join(root, dead))

      :ok = Workspace.ensure()

      listing = File.ls!(root)
      refute "sources" in listing
      refute "analysis" in listing
      refute "notes" in listing
    end

    # Decluttering never outranks not destroying someone's files.
    test "never removes a deprecated directory that holds anything", %{root: root} do
      File.mkdir_p!(Path.join(root, "notes"))
      File.write!(Path.join([root, "notes", "mine.md"]), "something I wrote")

      :ok = Workspace.ensure()

      assert "notes" in File.ls!(root)
      assert File.read!(Path.join([root, "notes", "mine.md"])) == "something I wrote"
    end

    test "sweep_deprecated/0 reports what it removed", %{root: root} do
      File.mkdir_p!(Path.join(root, "sources"))
      File.mkdir_p!(Path.join(root, "analysis"))
      File.mkdir_p!(Path.join(root, "notes"))
      File.write!(Path.join([root, "notes", "keep.md"]), "x")

      removed = Workspace.sweep_deprecated()

      assert Enum.sort(removed) == ["analysis", "sources"]
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
