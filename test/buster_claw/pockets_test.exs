defmodule BusterClaw.PocketsTest do
  # async: false — points the global :workspace_root / :library_root at tmp dirs.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Library, Pockets}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_pockets_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    prev_lib = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :library_root, Path.join(root, "library"))
    Library.ensure_directories()

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev_ws)
      Application.put_env(:buster_claw, :library_root, prev_lib)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp write_pocket(name, manifest, files \\ []) do
    dir = Pockets.pocket_dir(name)
    File.mkdir_p!(dir)
    if manifest, do: File.write!(Path.join(dir, "POCKET.md"), manifest)
    Enum.each(files, fn {file, body} -> File.write!(Path.join(dir, file), body) end)
    dir
  end

  defp manifest(fields) do
    """
    ---
    #{fields}
    ---

    The 32px versions are the ones that read at menu-bar size.
    """
  end

  describe "loading" do
    test "a well-formed pocket loads with its manifest and body" do
      write_pocket(
        "hazard-icons",
        manifest("""
        name: hazard-icons
        kind: icons
        description: Claw marks and hazard glyphs.
        roles: ["app_icon", "badge"]\
        """)
      )

      assert {:ok, pocket} = Pockets.load("hazard-icons")
      assert pocket.name == "hazard-icons"
      assert pocket.kind == :icons
      assert pocket.description == "Claw marks and hazard glyphs."
      assert pocket.roles == ["app_icon", "badge"]
      assert pocket.binding == :local
      assert pocket.dir == Pockets.pocket_dir("hazard-icons")
      assert pocket.body =~ "menu-bar size"
    end

    test "kind defaults to :free and roles to [] when the manifest is minimal" do
      write_pocket("scratch", manifest("description: Whatever."))

      assert {:ok, %{kind: :free, roles: []}} = Pockets.load("scratch")
    end

    test "a directory with no POCKET.md is not a pocket" do
      dir = Pockets.pocket_dir("bare")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "claw.png"), "x")

      assert {:error, :no_manifest} = Pockets.load("bare")
    end

    test "a manifest naming a different directory is refused, not renamed" do
      write_pocket("real-name", manifest("name: some-other-name\nkind: icons"))

      assert {:error, :name_mismatch} = Pockets.load("real-name")
    end

    test "an unknown kind is refused and names the offending value" do
      write_pocket("weird", manifest("kind: sculptures"))

      assert {:error, {:unknown_kind, "sculptures"}} = Pockets.load("weird")
    end

    test "a name that could escape the pockets directory is refused" do
      for name <- ["../evil", ".hidden", "Has Spaces", "up/down"] do
        assert {:error, :invalid_name} = Pockets.load(name),
               "#{inspect(name)} should not be a loadable pocket name"
      end
    end
  end

  describe "roles" do
    test "a bare (non-JSON) list is refused rather than read as punctuation" do
      # `roles: [app_icon, badge]` is not valid JSON, so Frontmatter hands it back
      # as a raw string. That must fail, not become a one-role list.
      write_pocket("bare-list", manifest("kind: icons\nroles: [app_icon, badge]"))

      assert {:error, :invalid_roles} = Pockets.load("bare-list")
    end

    test "roles stay strings — a manifest can never intern an atom" do
      name = "definitely_not_an_existing_atom_xyzzy"

      write_pocket("atomizer", manifest(~s|kind: icons\nroles: ["#{name}"]|))

      assert {:ok, %{roles: roles}} = Pockets.load("atomizer")
      assert roles == [name]
      assert Enum.all?(roles, &is_binary/1)

      # The load path must not have interned the role name. `POCKET.md` is
      # agent-writable, so `String.to_atom/1` on its contents would be unbounded
      # atom creation from attacker-influenced input, and atoms are never
      # collected.
      #
      # Asserting on the exact name rather than on :atom_count, which drifts for
      # reasons that have nothing to do with this code (first-call module loading
      # interns atoms too, and that made this test fail for the wrong reason).
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "a role with characters that are not role-shaped is refused" do
      write_pocket("shouty", manifest(~s|kind: icons\nroles: ["App Icon!"]|))

      assert {:error, :invalid_roles} = Pockets.load("shouty")
    end
  end

  describe "list" do
    test "lists valid pockets sorted, and skips invalid ones" do
      write_pocket("alpha", manifest("kind: icons"))
      write_pocket("zulu", manifest("kind: banners"))
      write_pocket("broken", manifest("kind: nonsense"))

      assert Enum.map(Pockets.list(), & &1.name) == ["alpha", "zulu"]
    end

    test "list_with_errors shows an invalid pocket as invalid, not as absent" do
      write_pocket("good", manifest("kind: icons"))
      write_pocket("broken", manifest("kind: nonsense"))

      results = Pockets.list_with_errors()

      assert {:ok, %{name: "good"}} = Enum.find(results, &match?({:ok, _}, &1))

      assert {:error, "broken", {:unknown_kind, "nonsense"}} =
               Enum.find(results, &match?({:error, _, _}, &1))
    end

    test "a file sitting next to the pocket directories is not mistaken for one" do
      Pockets.ensure()
      File.write!(Path.join(Pockets.dir(), "stray.txt"), "not a pocket")
      write_pocket("real", manifest("kind: icons"))

      assert Enum.map(Pockets.list(), & &1.name) == ["real"]
    end

    test "no pockets directory yet is an empty list, not a crash" do
      assert Pockets.list() == []
      assert Pockets.list_with_errors() == []
    end
  end

  describe "contents" do
    test "lists regular files, excluding the manifest and dotfiles" do
      write_pocket("kit", manifest("kind: icons"), [
        {"claw.png", "aaa"},
        {"badge.svg", "bb"},
        {".DS_Store", "junk"}
      ])

      {:ok, pocket} = Pockets.load("kit")

      assert [%{name: "badge.svg", bytes: 2}, %{name: "claw.png", bytes: 3}] =
               Pockets.contents(pocket)
    end

    test "a symlink inside a pocket is skipped, not followed out of it" do
      outside =
        Path.join(System.tmp_dir!(), "bc_pocket_outside_#{System.unique_integer([:positive])}")

      File.write!(outside, "secret")
      on_exit(fn -> File.rm_rf(outside) end)

      dir = write_pocket("linky", manifest("kind: icons"), [{"real.png", "ok"}])
      File.ln_s!(outside, Path.join(dir, "escape.png"))

      {:ok, pocket} = Pockets.load("linky")

      # A mount is the ONLY way a pocket reaches outside itself. A planted link
      # is not a mount, and it is not contents.
      assert Enum.map(Pockets.contents(pocket), & &1.name) == ["real.png"]
    end

    test "a subdirectory is not contents" do
      dir = write_pocket("nested", manifest("kind: icons"), [{"top.png", "x"}])
      File.mkdir_p!(Path.join(dir, "sub"))

      {:ok, pocket} = Pockets.load("nested")

      assert Enum.map(Pockets.contents(pocket), & &1.name) == ["top.png"]
    end
  end
end
