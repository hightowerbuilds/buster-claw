defmodule BusterClaw.NotesTest do
  # async: false — points the global :workspace_root at a tmp notes dir.
  use ExUnit.Case, async: false

  alias BusterClaw.Notes

  setup do
    root = Path.join(System.tmp_dir!(), "bc_notes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "create → save → get → list → delete round-trip", %{root: root} do
    assert {:ok, "Meeting Notes"} = Notes.create("Meeting Notes")
    assert File.exists?(Path.join([root, "notes", "Meeting Notes.md"]))

    assert {:ok, note} = Notes.save("Meeting Notes", "# Agenda\n\n- ship it")
    assert note.name == "Meeting Notes"
    assert note.body =~ "Agenda"

    assert %{name: "Meeting Notes", body: body} = Notes.get("Meeting Notes")
    assert body =~ "ship it"

    assert [%{name: "Meeting Notes"}] = Notes.list()

    assert :ok = Notes.delete("Meeting Notes")
    assert Notes.get("Meeting Notes") == nil
    assert Notes.list() == []
  end

  test "list is newest-first by modification time", %{root: root} do
    {:ok, "First"} = Notes.create("First")
    {:ok, "Second"} = Notes.create("Second")

    # posix mtime has 1-second resolution, so two creates in the same tick are a
    # tie; set explicit, distinct mtimes to pin the ordering deterministically.
    notes_dir = Path.join(root, "notes")
    File.touch!(Path.join(notes_dir, "First.md"), 1_700_000_000)
    File.touch!(Path.join(notes_dir, "Second.md"), 1_710_000_000)

    assert [%{name: "Second"}, %{name: "First"}] = Notes.list()
  end

  test "create rejects a blank or all-illegal title" do
    assert {:error, :blank} = Notes.create("   ")
    assert {:error, :blank} = Notes.create("///")
    assert {:error, :blank} = Notes.create(nil)
  end

  test "create refuses to clobber an existing note" do
    assert {:ok, "Dupe"} = Notes.create("Dupe")
    assert {:error, :exists} = Notes.create("Dupe")
  end

  test "titles are sanitized to a safe single filename component", %{root: root} do
    # Illegal filename characters are stripped; the surviving text is the name.
    assert {:ok, name} = Notes.create(~s(Q3: plan/draft?))
    refute String.contains?(name, ["/", ":", "?"])
    assert File.exists?(Path.join([root, "notes", name <> ".md"]))
    # And it did not escape the notes directory.
    assert Path.dirname(Path.join([root, "notes", name <> ".md"])) == Path.join(root, "notes")
  end

  test "path traversal is refused on every lookup", %{root: root} do
    # A pre-seeded secret outside notes/ must never be reachable by name.
    File.write!(Path.join(root, "secret.md"), "top secret")

    assert Notes.get("../secret") == nil
    assert Notes.save("../secret", "overwritten") == {:error, :invalid}
    assert Notes.delete("../secret") == {:error, :invalid}
    assert Notes.get("../../etc/passwd") == nil

    # The out-of-bounds file is untouched.
    assert File.read!(Path.join(root, "secret.md")) == "top secret"
  end

  test "save to a non-existent note does not mint a file", %{root: root} do
    assert {:error, :not_found} = Notes.save("Ghost", "boo")
    refute File.exists?(Path.join([root, "notes", "Ghost.md"]))
  end
end
