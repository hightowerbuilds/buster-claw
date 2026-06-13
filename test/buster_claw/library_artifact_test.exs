defmodule BusterClaw.LibraryArtifactTest do
  use BusterClaw.DataCase

  alias BusterClaw.Library
  alias BusterClaw.Library.Artifact
  alias BusterClaw.Repo

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-library-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, previous)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "ensures raw and report directories", %{root: root} do
    assert :ok = Library.ensure_directories()
    assert File.dir?(Path.join(root, "raw"))
    assert File.dir?(Path.join(root, "reports"))
  end

  test "saves and reads raw markdown with frontmatter metadata" do
    assert {:ok, document} =
             Library.save_raw_document(%{
               date: ~D[2026-05-07],
               filename: "My Source.md",
               source_url: "https://example.com/story",
               name: "My Source",
               tags: ["ai", "research"],
               content: "# Heading\n\nUseful body."
             })

    assert document.filename == "my-source.md"
    assert document.artifact_path == "raw/2026-05-07/my-source.md"
    assert document.source_url == "https://example.com/story"
    assert document.name == "My Source"
    assert document.tags == %{"items" => ["ai", "research"]}
    assert byte_size(document.content_hash) == 64

    assert {:ok, body} = Library.read_raw_document(document)
    assert body =~ "# Heading"
    refute body =~ "source_url"
  end

  test "rejects raw reads outside library" do
    assert {:error, :outside_library} = Artifact.read_raw_document("/tmp/not-inside-library.md")
  end

  test "content_hash is the body hash, stable across differing frontmatter" do
    assert {:ok, first} =
             Library.save_raw_document(%{
               date: ~D[2026-05-07],
               filename: "snapshot.md",
               name: "Snapshot",
               source_url: "https://example.com/s",
               tags: ["integration"],
               content: "# Body\n\nIdentical body text.",
               fetched_at: ~U[2026-05-07 10:00:00Z]
             })

    # Same body, different fetched_at (which lands in frontmatter) and a
    # distinct artifact path: the stored content_hash must still match.
    assert {:ok, second} =
             Library.save_raw_document(%{
               date: ~D[2026-05-08],
               filename: "snapshot.md",
               name: "Snapshot",
               source_url: "https://example.com/s",
               tags: ["integration"],
               content: "# Body\n\nIdentical body text.",
               fetched_at: ~U[2026-05-08 18:30:00Z]
             })

    assert first.content_hash == second.content_hash
    assert first.content_hash == Library.body_hash("# Body\n\nIdentical body text.")
  end

  test "list_documents/1 scopes by tag and since date" do
    {:ok, _old} =
      Library.save_raw_document(%{
        date: ~D[2026-01-01],
        filename: "old.md",
        tags: ["integration", "github"],
        content: "old"
      })

    {:ok, recent} =
      Library.save_raw_document(%{
        date: ~D[2026-06-01],
        filename: "recent.md",
        tags: ["integration", "github"],
        content: "recent"
      })

    {:ok, _other} =
      Library.save_raw_document(%{
        date: ~D[2026-06-01],
        filename: "other.md",
        tags: ["research"],
        content: "other"
      })

    scoped = Library.list_documents(tag: "github", since: ~D[2026-05-01])
    assert [doc] = scoped
    assert doc.id == recent.id
  end

  test "deletes raw document artifact and marks metadata deleted" do
    assert {:ok, document} =
             Library.save_raw_document(%{
               date: ~D[2026-05-07],
               filename: "delete-me.md",
               content: "temporary"
             })

    path = Library.absolute_artifact_path(document.artifact_path)
    assert File.exists?(path)

    assert {:ok, document} = Library.delete_raw_document(document)
    refute File.exists?(path)
    assert Repo.reload!(document).status == "deleted"
  end
end
