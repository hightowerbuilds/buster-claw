defmodule BusterClaw.NotesTest do
  # async: false — points the global :workspace_root at a temporary Notes vault.
  use ExUnit.Case, async: false

  alias BusterClaw.Notes

  setup do
    root = Path.join(System.tmp_dir!(), "bc_notes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, previous)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "create, conflict-safe save, read, list, and delete round-trip", %{root: root} do
    assert {:ok, created} = Notes.create("Meeting Notes")
    assert created.path == "Meeting Notes.md"
    assert File.exists?(Path.join([root, "notes", "Meeting Notes.md"]))

    assert {:ok, saved} =
             Notes.save(created.path, "# Agenda\n\n- ship it", created.revision)

    assert saved.body =~ "ship it"
    assert saved.revision != created.revision
    assert %{path: "Meeting Notes.md", body: body} = Notes.get("Meeting Notes.md")
    assert body =~ "Agenda"
    assert [%{path: "Meeting Notes.md"}] = Notes.list()

    assert :ok = Notes.delete("Meeting Notes.md")
    assert Notes.get("Meeting Notes.md") == nil
    assert Notes.list() == []
  end

  test "a stale revision returns both versions without overwriting disk", %{root: root} do
    {:ok, opened} = Notes.create("Remote access")
    disk_path = Path.join([root, "notes", opened.path])
    File.write!(disk_path, "newer disk version")

    assert {:error, {:conflict, current}} =
             Notes.save(opened.path, "my unsaved draft", opened.revision)

    assert current.body == "newer disk version"
    assert File.read!(disk_path) == "newer disk version"

    assert {:ok, overwritten} = Notes.save(opened.path, "my unsaved draft", :force)
    assert overwritten.body == "my unsaved draft"
  end

  test "lists nested Markdown while ignoring other files and symlinks", %{root: root} do
    assert :ok = Notes.create_folder("Projects")
    assert {:ok, note} = Notes.create("Launch", "Projects")
    assert note.path == "Projects/Launch.md"

    File.write!(Path.join([root, "notes", "Projects", "ignore.txt"]), "not a note")
    File.ln_s!(Path.join(root, "outside.md"), Path.join([root, "notes", "outside-link.md"]))

    assert [%{path: "Projects/Launch.md"}] = Notes.list()
  end

  test "titles are sanitized and lookups cannot escape the vault", %{root: root} do
    assert {:ok, note} = Notes.create(~s(Q3: plan/draft?))
    refute String.contains?(note.path, ["/", ":", "?"])

    File.write!(Path.join(root, "secret.md"), "top secret")

    assert {:error, :invalid_path} = Notes.get("../secret.md")
    assert {:error, :invalid_path} = Notes.save("../secret.md", "overwritten", :force)
    assert {:error, :invalid_path} = Notes.delete("../secret.md")
    assert File.read!(Path.join(root, "secret.md")) == "top secret"
  end

  test "rename and move relocate a note without ever clobbering one", %{root: root} do
    vault = Path.join(root, "notes")
    assert :ok = Notes.create_folder("Projects")
    assert {:ok, note} = Notes.create("Draft")
    assert {:ok, _occupied} = Notes.create("Taken", "Projects")

    assert {:ok, renamed} = Notes.rename(note.path, "Launch plan")
    assert renamed.path == "Launch plan.md"
    refute File.exists?(Path.join(vault, "Draft.md"))

    assert {:ok, moved} = Notes.move(renamed.path, "Projects")
    assert moved.path == "Projects/Launch plan.md"
    refute File.exists?(Path.join(vault, "Launch plan.md"))
    assert File.exists?(Path.join([vault, "Projects", "Launch plan.md"]))

    # A collision leaves BOTH files exactly as they were.
    assert {:error, :exists} = Notes.rename(moved.path, "Taken")
    assert File.exists?(Path.join([vault, "Projects", "Launch plan.md"]))
    assert {:error, :folder_not_found} = Notes.move(moved.path, "Nowhere")
    assert {:error, :invalid_path} = Notes.move(moved.path, "../..")
    assert [%{path: "Projects/Launch plan.md"}, %{path: "Projects/Taken.md"}] = Notes.list()

    # A traversal in the NEW name is sanitized into a filename, exactly as it is
    # on create — the note stays in its folder rather than the rename failing.
    assert {:ok, %{path: "Projects/escaped.md"}} = Notes.rename(moved.path, "../escaped")
    refute File.exists?(Path.join(root, "escaped.md"))
  end

  test "folders are listed for the UI and dot-directories stay invisible", %{root: root} do
    assert :ok = Notes.create_folder("Projects/2026")
    assert :ok = Notes.create_folder("Inbox")
    File.mkdir_p!(Path.join([root, "notes", ".trash"]))
    File.write!(Path.join([root, "notes", ".trash", "gone.md"]), "deleted")

    assert Notes.folders() == ["Inbox", "Projects", "Projects/2026"]
    assert Notes.list() == []
  end

  test "an oversized note is listed as unsupported and never read into memory", %{root: root} do
    File.mkdir_p!(Path.join(root, "notes"))
    File.write!(Path.join([root, "notes", "Huge.md"]), String.duplicate("x", 1_000_001))
    assert {:ok, _small} = Notes.create("Small")

    assert [%{path: "Huge.md", supported: false}, %{path: "Small.md", supported: true}] =
             Enum.sort_by(Notes.list(), & &1.path)

    assert {:error, :too_large} = Notes.get("Huge.md")
  end

  test "foldered notes sort ahead of loose ones so the rail can group them" do
    assert :ok = Notes.create_folder("Projects")
    assert {:ok, _} = Notes.create("Alpha")
    assert {:ok, _} = Notes.create("zeta", "Projects")

    assert ["Projects/zeta.md", "Alpha.md"] = Enum.map(Notes.list(), & &1.path)
  end

  test "search reads titles and bodies and returns a usable snippet", %{root: root} do
    {:ok, note} = Notes.create("Remote access")

    {:ok, _saved} =
      Notes.save(
        note.path,
        "# Remote access\n\nKeep Phoenix on loopback and tunnel with ssh -L.\n",
        note.revision
      )

    assert [%{path: "Remote access.md", snippet: snippet}] = Notes.search("LOOPBACK")
    assert snippet =~ "loopback"
    refute snippet =~ "\n"

    # A title-only match still gets a snippet — the note's opening line.
    assert [%{snippet: opening}] = Notes.search("remote")
    assert opening =~ "Remote access"

    assert Notes.search("nothing here") == []
    assert Notes.search("   ") == []

    # Oversized files are skipped rather than read into memory to be searched.
    File.write!(Path.join([root, "notes", "Huge.md"]), String.duplicate("loopback ", 200_000))
    assert [%{path: "Remote access.md"}] = Notes.search("loopback")
  end

  test "a snippet around a multi-byte match stays valid UTF-8" do
    {:ok, note} = Notes.create("Unicode")
    body = String.duplicate("→ ", 60) <> "needle" <> String.duplicate(" ←", 60)
    {:ok, _saved} = Notes.save(note.path, body, note.revision)

    assert [%{snippet: snippet}] = Notes.search("needle")
    assert String.valid?(snippet)
    assert snippet =~ "needle"
  end

  test "backlinks and link resolution follow the vault, not an index" do
    assert :ok = Notes.create_folder("Projects")
    {:ok, target} = Notes.create("Remote access")
    {:ok, source} = Notes.create("Launch", "Projects")

    {:ok, _saved} =
      Notes.save(
        source.path,
        "See [[Remote access]] and [[Ghost]].\n\n```\n[[Remote access]]\n```\n",
        source.revision
      )

    assert [%{path: "Projects/Launch.md"}] = Notes.backlinks(target.path)
    assert Notes.backlinks(source.path) == []

    assert Notes.resolve_link("Remote access") == "Remote access.md"
    assert Notes.resolve_link("Remote access.md") == "Remote access.md"
    assert Notes.resolve_link("Projects/Launch") == "Projects/Launch.md"
    assert Notes.resolve_link("Ghost") == nil
    assert Notes.resolve_link("") == nil
    assert Notes.resolve_link(nil) == nil
  end

  test "blank and duplicate titles are rejected" do
    assert {:error, :blank} = Notes.create("   ")
    assert {:error, :blank} = Notes.create("///")
    assert {:error, :blank} = Notes.create(nil)

    assert {:ok, _note} = Notes.create("Dupe")
    assert {:error, :exists} = Notes.create("Dupe")
  end
end
