defmodule BusterClaw.LibraryDocumentTest do
  use BusterClaw.DataCase

  alias BusterClaw.Library

  test "documents point to markdown artifact paths and enforce uniqueness" do
    assert {:ok, document} =
             Library.create_document(%{
               filename: "example.md",
               artifact_path: "Library/raw/2026-05-07/example.md",
               date: ~D[2026-05-07],
               source_url: "https://example.com/a",
               content_hash: "abc123",
               status: "fetched"
             })

    assert [^document] = Library.list_documents()

    assert {:error, changeset} =
             Library.create_document(%{
               filename: "example.md",
               artifact_path: "Library/raw/2026-05-07/example.md",
               status: "fetched"
             })

    assert %{artifact_path: [_]} = errors_on(changeset)
  end
end
