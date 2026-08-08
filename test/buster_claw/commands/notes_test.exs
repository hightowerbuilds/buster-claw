defmodule BusterClaw.Commands.NotesTest do
  # async: false — points the global :workspace_root at a temporary Notes vault.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Commands
  alias BusterClaw.Notes

  setup do
    root = Path.join(System.tmp_dir!(), "bc_note_cmd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, previous)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "the note commands round-trip through the same vault the UI uses", %{root: root} do
    assert :ok = Notes.create_folder("Projects")

    assert {:ok, created} =
             Commands.call("note_create", %{
               "title" => "Launch",
               "folder" => "Projects",
               "body" => "# Launch\n\nShip on Friday.\n"
             })

    assert created.path == "Projects/Launch.md"
    assert File.read!(Path.join([root, "notes", "Projects", "Launch.md"])) =~ "Ship on Friday"

    assert {:ok, %{notes: [%{path: "Projects/Launch.md"}]}} = Commands.call("note_list", %{})

    assert {:ok, read} = Commands.call("note_read", %{"path" => "Projects/Launch.md"})
    assert read.body =~ "Ship on Friday"
    refute Map.has_key?(read, :size)

    assert {:ok, %{results: [%{path: "Projects/Launch.md", snippet: snippet}]}} =
             Commands.call("note_search", %{"query" => "friday"})

    assert snippet =~ "Friday"

    assert {:ok, saved} =
             Commands.call("note_save", %{
               "path" => read.path,
               "body" => "# Launch\n\nShip on Monday.\n",
               "revision" => read.revision
             })

    assert saved.revision != read.revision
    refute Map.has_key?(saved, :body)
  end

  test "a stale revision is refused with the current one, and nothing is written" do
    {:ok, note} = Commands.call("note_create", %{"title" => "Shared", "body" => "original\n"})
    {:ok, opened} = Commands.call("note_read", %{"path" => note.path})

    # The operator (or another agent) writes first.
    {:ok, newer} = Notes.save(note.path, "operator's newer text\n", opened.revision)

    assert {:error, {:conflict, revision}} =
             Commands.call("note_save", %{
               "path" => note.path,
               "body" => "agent's guess\n",
               "revision" => opened.revision
             })

    # The current revision comes back so a re-read is possible; the body does
    # not, so a merge has to be a deliberate note_read rather than a diff
    # smuggled through an error.
    assert revision == newer.revision
    assert %{body: "operator's newer text\n"} = Notes.get(note.path)
  end

  test "the vault is the boundary: no absolute paths, no traversal, no delete" do
    File.write!(Path.join(Notes.dir() |> Path.dirname(), "secret.md"), "top secret")

    assert {:error, :invalid_path} = Commands.call("note_read", %{"path" => "../secret.md"})
    assert {:error, :invalid_path} = Commands.call("note_read", %{"path" => "/etc/hosts"})

    assert {:error, :invalid_path} =
             Commands.call("note_save", %{
               "path" => "../secret.md",
               "body" => "overwritten",
               "revision" => "sha256:whatever"
             })

    assert File.read!(Path.join(Notes.dir() |> Path.dirname(), "secret.md")) == "top secret"

    # Deleting a note stays a human action in the UI.
    refute "note_delete" in Enum.map(Commands.list_commands(), & &1.name)
  end

  test "missing arguments are refused rather than guessed" do
    assert {:error, :missing_path} = Commands.call("note_read", %{})
    assert {:error, :missing_title} = Commands.call("note_create", %{})
    assert {:error, :missing_query} = Commands.call("note_search", %{})
    assert {:error, :missing_path_body_or_revision} = Commands.call("note_save", %{"path" => "a"})
  end

  test "the audit row records that a note changed, never what it says" do
    {:ok, _note} =
      Commands.call("note_create", %{"title" => "Private", "body" => "my therapist said"})

    events = BusterClaw.Sentinel.list_events(limit: 50)
    row = Enum.find(events, &(&1.metadata["command"] == "note_create"))

    assert row, "note_create should be audited — it is a mutation"
    assert row.metadata["args"]["title"] == "Private"
    assert row.metadata["args"]["body"] == "<17 bytes>"
    refute inspect(row.metadata) =~ "therapist"
  end
end
