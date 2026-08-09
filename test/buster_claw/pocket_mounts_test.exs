defmodule BusterClaw.PocketMountsTest do
  @moduledoc """
  Phase 3 of `daily-growth/archive/08-09-26-pockets-roadmap.md` — the mount.

  A mount is the one real trust expansion in the roadmap: it lets the app read
  bytes outside the workspace on purpose, having spent three layers of code
  making sure it could not do so by accident. So the tests that matter are not
  the round trip; they are the six the roadmap names as the price of calling the
  phase done, and each has its own `describe` block below.
  """

  # async: false — points the global :workspace_root / :library_root at tmp dirs.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Library, Orchestration, Pockets, Settings}
  alias BusterClaw.Pockets.Mounts

  setup do
    root = Path.join(System.tmp_dir!(), "bc_mounts_#{System.unique_integer([:positive])}")
    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    prev_lib = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :workspace_root, Path.join(root, "workspace"))
    Application.put_env(:buster_claw, :library_root, Path.join(root, "workspace/library"))
    Library.ensure_directories()
    Pockets.ensure()

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev_ws)
      Application.put_env(:buster_claw, :library_root, prev_lib)
      File.rm_rf(root)
    end)

    {:ok, root: root, outside: outside}
  end

  # A Pocket's manifest ALWAYS lives in the workspace, mounted or not. That is
  # the D4/D5 split made concrete: the description is agent-writable, the reach
  # is not.
  defp write_pocket(name, kind \\ "media") do
    dir = Pockets.pocket_dir(name)
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "POCKET.md"), """
    ---
    name: #{name}
    kind: #{kind}
    description: Files that live somewhere else.
    ---

    The mount is recorded by the app, not by this file.
    """)

    dir
  end

  defp target(root, name, files \\ []) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    Enum.each(files, fn {file, body} -> File.write!(Path.join(dir, file), body) end)
    dir
  end

  # ------------------------------------------------------------------------
  # The registry itself
  # ------------------------------------------------------------------------

  describe "the registry" do
    test "records a mount and reads it back", %{root: root} do
      dir = target(root, "typefaces")

      assert {:ok, mount} = Mounts.mount("typefaces", dir)
      assert mount.name == "typefaces"
      assert mount.path == dir
      assert mount.writable == false
      assert is_binary(mount.mounted_at)

      assert {:ok, ^mount} = Mounts.fetch("typefaces")
      assert Mounts.mounted?("typefaces")
      assert [%{name: "typefaces"}] = Mounts.list()
    end

    test "lives outside the workspace entirely", %{root: root} do
      dir = target(root, "typefaces")
      {:ok, _} = Mounts.mount("typefaces", dir)

      # Not a file. Not in the Pocket. Not anywhere the agent's file surface
      # reaches — if this ever becomes a path, D4 is gone.
      assert Settings.get("pocket_mount:typefaces") =~ dir
      refute File.exists?(Path.join(Pockets.pocket_dir("typefaces"), "MOUNT"))
    end

    test "read-only unless the operator says otherwise", %{root: root} do
      dir = target(root, "exports")

      assert {:ok, %{writable: false}} = Mounts.mount("exports", dir)
      assert {:ok, %{writable: true}} = Mounts.mount("exports", dir, writable: true)
      assert {:ok, %{writable: false}} = Mounts.mount("exports", dir, writable: "yes")
    end

    test "refuses a name that is not a legal Pocket name", %{root: root} do
      dir = target(root, "ok")

      for name <- ["../escape", "Caps", "with space", "-leading", "", "a/b"] do
        assert {:error, :invalid_name} = Mounts.mount(name, dir), "accepted #{inspect(name)}"
      end
    end

    test "refuses a relative path", %{root: root} do
      _ = target(root, "rel")
      assert {:error, :not_absolute} = Mounts.mount("rel", "rel")
      assert {:error, :invalid_path} = Mounts.mount("rel", "")
    end

    test "refuses the two roots that make the sandbox decorative" do
      assert {:error, :too_broad} = Mounts.mount("everything", "/")
      assert {:error, :too_broad} = Mounts.mount("everything", BusterClaw.FileManager.home())
    end

    test "an unreadable row degrades to not mounted" do
      Settings.put("pocket_mount:corrupt", "{not json")

      assert Mounts.fetch("corrupt") == :error
      assert Mounts.list() == []
    end

    test "unmounting deletes the row and nothing on disk", %{root: root} do
      dir = target(root, "keepme", [{"a.txt", "still here"}])
      {:ok, _} = Mounts.mount("keepme", dir)

      assert :ok = Mounts.unmount("keepme")
      assert Mounts.fetch("keepme") == :error
      assert File.read!(Path.join(dir, "a.txt")) == "still here"
    end
  end

  # ------------------------------------------------------------------------
  # The loader
  # ------------------------------------------------------------------------

  describe "a mounted Pocket" do
    test "loads with its manifest local and its bytes elsewhere", %{root: root} do
      write_pocket("typefaces", "fonts")
      dir = target(root, "Fonts", [{"claw.otf", "font bytes"}])
      {:ok, _} = Mounts.mount("typefaces", dir)

      assert {:ok, pocket} = Pockets.load("typefaces")

      # The description came from the workspace; the reach came from the registry.
      assert pocket.kind == :fonts
      assert pocket.description == "Files that live somewhere else."
      assert pocket.binding == {:mounted, dir, false}
      assert pocket.dir == dir
      refute pocket.dir == Pockets.pocket_dir("typefaces")

      # `pocket.dir` is the mount path, so no caller has to know which case it
      # is in — contents and resolve both just work.
      assert [%{name: "claw.otf", bytes: 10}] = Pockets.contents(pocket)
      assert Pockets.resolve(pocket, "claw.otf") == Path.join(dir, "claw.otf")
      assert Pockets.asset_url(pocket, "claw.otf") =~ "/pockets/typefaces/claw.otf?v="
    end

    test "does not show the files sitting beside its manifest", %{root: root} do
      local = write_pocket("typefaces")
      File.write!(Path.join(local, "leftover.png"), "x")
      dir = target(root, "Fonts", [{"claw.otf", "f"}])
      {:ok, _} = Mounts.mount("typefaces", dir)

      {:ok, pocket} = Pockets.load("typefaces")
      assert Enum.map(Pockets.contents(pocket), & &1.name) == ["claw.otf"]
      assert Pockets.resolve(pocket, "leftover.png") == nil
    end

    test "appears in the list beside local ones", %{root: root} do
      write_pocket("local-one")
      write_pocket("mounted-one")
      dir = target(root, "elsewhere", [{"a.png", "a"}])
      {:ok, _} = Mounts.mount("mounted-one", dir)

      assert [local, mounted] = Pockets.list()
      assert local.binding == :local
      assert mounted.binding == {:mounted, dir, false}
    end
  end

  # ------------------------------------------------------------------------
  # Roadmap test 1 — a symlink inside a mount cannot escape it
  # ------------------------------------------------------------------------

  describe "containment inside a mount" do
    setup %{root: root} do
      write_pocket("media")
      dir = target(root, "Media", [{"ok.png", "fine"}])
      secrets = target(root, "secrets", [{"id_rsa", "PRIVATE KEY"}])
      {:ok, _} = Mounts.mount("media", dir)
      {:ok, pocket} = Pockets.load("media")
      {:ok, pocket: pocket, dir: dir, secrets: secrets}
    end

    test "a planted symlink to a file outside cannot be read", ctx do
      :ok = File.ln_s(Path.join(ctx.secrets, "id_rsa"), Path.join(ctx.dir, "innocent.png"))

      # Guard 3 (`within?/2` re-canonicalizes and re-checks) fires before the
      # lstat ever runs. A mount is a NEW ROOT, not a hole.
      assert Pockets.resolve(ctx.pocket, "innocent.png") == nil
      assert Enum.map(Pockets.contents(ctx.pocket), & &1.name) == ["ok.png"]
      assert Pockets.asset_url(ctx.pocket, "innocent.png") == nil
    end

    test "a planted symlink to a directory outside cannot be traversed", ctx do
      :ok = File.ln_s(ctx.secrets, Path.join(ctx.dir, "out"))

      assert Pockets.resolve(ctx.pocket, "out") == nil
      # And the bare-name guard means the traversal cannot even be spelled.
      assert Pockets.resolve(ctx.pocket, "out/id_rsa") == nil
      assert Pockets.resolve(ctx.pocket, "../secrets/id_rsa") == nil
      assert Enum.map(Pockets.contents(ctx.pocket), & &1.name) == ["ok.png"]
    end

    test "a symlink that stays inside the mount is still refused", ctx do
      :ok = File.ln_s(Path.join(ctx.dir, "ok.png"), Path.join(ctx.dir, "alias.png"))

      # Not an escape, but `lstat` sees a link and skips it either way. The rule
      # is "a Pocket reaches outside itself only through a mount", and a link is
      # never allowed to be the second way.
      assert Pockets.resolve(ctx.pocket, "alias.png") == nil
      assert Enum.map(Pockets.contents(ctx.pocket), & &1.name) == ["ok.png"]
    end
  end

  # ------------------------------------------------------------------------
  # Roadmap test 2 — the `<> "/"` boundary bug, explicitly
  # ------------------------------------------------------------------------

  describe "a root that merely looks like a mount root" do
    test "sharing a prefix with a mount is not being inside it", %{root: root} do
      good = target(root, "Pockets", [{"f.txt", "mine"}])
      evil = target(root, "Pockets-evil", [{"f.txt", "theirs"}])

      {:ok, _} = Mounts.mount("safe", good)

      # The registered root resolves.
      assert Pockets.resolve(%{dir: good}, "f.txt") == Path.join(good, "f.txt")

      # Its prefix-sharing neighbour does NOT. This is the `<> "/"` boundary in
      # `FileManager.within?/2`; a `String.starts_with?` without it would hand
      # over `/Users/x/Pockets-evil` on the strength of `/Users/x/Pockets`.
      assert Pockets.resolve(%{dir: evil}, "f.txt") == nil
      assert Pockets.contents(%{dir: evil}) == []
      refute Mounts.registered_root?(evil)
      assert Mounts.registered_root?(good)

      # Same check one level up, where the prefix is a real ancestor rather
      # than a lexical one.
      refute Mounts.registered_root?(root)
      assert Mounts.registered_root?(Path.join(good, "nested"))
    end

    test "an unregistered root resolves and lists nothing" do
      assert Pockets.resolve(%{dir: "/etc"}, "hosts") == nil
      assert Pockets.contents(%{dir: "/etc"}) == []
      assert Pockets.contents(%{dir: nil}) == []
      assert Pockets.contents("not a pocket") == []
    end
  end

  # ------------------------------------------------------------------------
  # Roadmap tests 3 and 4 — bad targets, missing targets
  # ------------------------------------------------------------------------

  describe "a target that is not a usable directory" do
    test "a mount pointing at a file is refused", %{root: root} do
      file = Path.join(root, "a-file.png")
      File.write!(file, "not a directory")

      assert {:error, :not_a_directory} = Mounts.mount("wrong", file)
      assert Mounts.fetch("wrong") == :error
    end

    test "a mount pointing at nothing is refused", %{root: root} do
      assert {:error, :not_found} = Mounts.mount("ghost", Path.join(root, "never-existed"))
    end

    test "a target deleted AFTER mounting degrades to empty, never raises", %{root: root} do
      write_pocket("gone")
      dir = target(root, "vanishing", [{"a.png", "a"}])
      {:ok, _} = Mounts.mount("gone", dir)

      {:ok, before} = Pockets.load("gone")
      assert [%{name: "a.png"}] = Pockets.contents(before)

      File.rm_rf!(dir)

      # Still a Pocket, still says what it is for, still says it is mounted —
      # it simply has no contents. Invalid is a state the UI can draw; a crash
      # is not.
      assert {:ok, pocket} = Pockets.load("gone")
      assert pocket.binding == {:mounted, dir, false}
      assert Pockets.contents(pocket) == []
      assert Pockets.resolve(pocket, "a.png") == nil
      assert Pockets.asset_url(pocket, "a.png") == nil
      assert [%{name: "gone"}] = Pockets.list()
    end
  end

  # ------------------------------------------------------------------------
  # Roadmap test 5 — revocation is immediate
  # ------------------------------------------------------------------------

  describe "unmounting" do
    test "makes the bytes unreachable immediately", %{root: root} do
      write_pocket("borrowed")
      dir = target(root, "lent", [{"a.png", "a"}])
      {:ok, _} = Mounts.mount("borrowed", dir)

      {:ok, mounted} = Pockets.load("borrowed")
      assert Pockets.resolve(mounted, "a.png") == Path.join(dir, "a.png")

      :ok = Mounts.unmount("borrowed")

      # Reloading gives a local Pocket pointing back inside the workspace.
      assert {:ok, local} = Pockets.load("borrowed")
      assert local.binding == :local
      assert local.dir == Pockets.pocket_dir("borrowed")
      assert Pockets.contents(local) == []

      # And — the part that matters — a Pocket loaded BEFORE the unmount is dead
      # too. The resolver re-asks the registry on every call and caches nothing,
      # so a stale handle is not a lingering grant.
      assert Pockets.resolve(mounted, "a.png") == nil
      assert Pockets.contents(mounted) == []
      assert File.exists?(Path.join(dir, "a.png"))
    end
  end

  # ------------------------------------------------------------------------
  # Roadmap test 6 — D5, write is a grant and never unattended
  # ------------------------------------------------------------------------

  describe "write" do
    setup %{root: root} do
      write_pocket("scratch")
      dir = target(root, "Scratch", [{"a.png", "a"}])
      {:ok, _} = Mounts.mount("scratch", dir, writable: true)
      {:ok, pocket} = Pockets.load("scratch")
      {:ok, pocket: pocket, dir: dir}
    end

    test "a granted mount is writable by the operator", ctx do
      assert ctx.pocket.binding == {:mounted, ctx.dir, true}
      assert Pockets.writable?(ctx.pocket, :trusted)
    end

    test "is refused to every caller that is not the operator", ctx do
      for caller <- [:agent, :agent_untrusted, :mcp, nil, :made_up] do
        refute Pockets.writable?(ctx.pocket, caller), "granted write to #{inspect(caller)}"
      end
    end

    test "is refused while an UNATTENDED shift is running", ctx do
      {:ok, _shift} = Orchestration.start_shift(job: "lookout", unattended: true)

      # The caller atom alone would say yes here: `Dispatcher.token_for/1` hands
      # an unattended run the FULL api token whenever its queue provenance is
      # trusted, so an unattended run presents as `:trusted`. Detecting
      # unattended therefore takes the app's own record of the machine's state
      # as well, and this is the assertion that pins that.
      refute Mounts.attended?(:trusted)
      refute Pockets.writable?(ctx.pocket, :trusted)

      # Read is untouched by any of it. A mount widens what may be READ.
      assert Pockets.resolve(ctx.pocket, "a.png") == Path.join(ctx.dir, "a.png")
      assert [%{name: "a.png"}] = Pockets.contents(ctx.pocket)
    end

    test "is allowed while an ATTENDED shift is running", ctx do
      {:ok, _shift} = Orchestration.start_shift(job: "lookout")

      assert Mounts.attended?(:trusted)
      assert Pockets.writable?(ctx.pocket, :trusted)
    end

    test "is refused on a mount with no grant, operator or not", %{root: root} do
      write_pocket("readonly")
      dir = target(root, "ReadOnly", [{"a.png", "a"}])
      {:ok, _} = Mounts.mount("readonly", dir)
      {:ok, pocket} = Pockets.load("readonly")

      refute Pockets.writable?(pocket, :trusted)
      assert Pockets.resolve(pocket, "a.png") == Path.join(dir, "a.png")
    end

    test "a local Pocket is governed by the workspace, not by this" do
      write_pocket("home-grown")
      {:ok, pocket} = Pockets.load("home-grown")

      # `true` is the honest answer: the directory is inside the workspace and
      # `FileManager.within?/2` already governs it. Saying `false` here would be
      # a fence that does not exist anywhere in the code.
      assert Pockets.writable?(pocket, :trusted)
      assert Pockets.writable?(pocket, :agent)
      refute Pockets.writable?(%{binding: :nonsense}, :trusted)
      refute Pockets.writable?(nil, :trusted)
    end
  end

  # ------------------------------------------------------------------------
  # D4 — enforced by structure. Lockstep, same idiom as the ACL suite.
  # ------------------------------------------------------------------------

  describe "the agent may read a mounted Pocket, never mount one" do
    test "no command in the catalog can create or remove a mount" do
      names = Enum.map(BusterClaw.Commands.list_commands(), & &1.name)

      for name <- names do
        refute name =~ ~r/mount/i, "#{name} looks like a mount verb — D4 says there is none"
      end
    end

    test "no module on the command surface can reach the registry" do
      offenders =
        "lib/buster_claw/commands/**/*.ex"
        |> Path.wildcard()
        |> Enum.concat(["lib/buster_claw/commands.ex"])
        |> Enum.filter(fn path ->
          File.read!(path) =~ ~r/Pockets\.Mounts|pocket_mount|Settings\.(put|delete)/
        end)

      assert offenders == [],
             """
             D4: the mount registry is written by one surface, and the command
             layer is not it. These files reach it:

             #{Enum.join(offenders, "\n")}
             """
    end
  end

  # ------------------------------------------------------------------------
  # The one duplicated rule
  # ------------------------------------------------------------------------

  describe "the name rule" do
    test "is the same in the registry as in the loader" do
      # `Mounts` keeps its own copy of the regex so it never has to call back
      # into `Pockets`. A mount key that is not a legal Pocket name could never
      # be looked up, so the two must not drift.
      names = [
        "ok",
        "a",
        "a-b-c",
        "a1",
        "Caps",
        "-lead",
        "with space",
        "a/b",
        "",
        "..",
        ".hidden"
      ]

      for name <- names do
        loader_ok = Pockets.load(name) != {:error, :invalid_name}
        assert Mounts.valid_name?(name) == loader_ok, "disagreement on #{inspect(name)}"
      end
    end
  end
end
