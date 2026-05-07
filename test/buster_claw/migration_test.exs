defmodule BusterClaw.MigrationTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Calendar, Library, Memory, Migration, Providers, Sources}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-migration-test-#{System.unique_integer([:positive])}"
      )

    library_root = Path.join(root, "Library")
    File.mkdir_p!(library_root)

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, library_root: library_root}
  end

  test "imports legacy memory, calendar, sources, and providers idempotently", %{
    root: root,
    library_root: library_root
  } do
    File.write!(Path.join(library_root, "Memory.md"), """
    # Memory

    - Keep imports idempotent.
    - Index markdown in place.
    """)

    File.write!(
      Path.join(library_root, "calendar.json"),
      Jason.encode!(%{
        events: [
          %{id: "event-1", date: "2026-05-07", title: "Rewrite", notes: "Phase 15"}
        ]
      })
    )

    File.write!(
      Path.join(root, "sources.json"),
      Jason.encode!(%{
        sources: [
          %{url: "https://example.com/feed.xml", type: "rss", name: "Feed", tags: ["ai"]}
        ]
      })
    )

    File.write!(
      Path.join(root, "providers.json"),
      Jason.encode!(%{
        providers: [
          %{name: "local", type: "ollama", model: "llama3", active: true}
        ]
      })
    )

    assert %{memories: %{created: 2}, calendar_events: %{created: 1}} =
             Migration.import_all(legacy_root: root, library_root: library_root)

    assert length(Memory.list_memories()) == 2
    assert [%{event_id: "event-1"}] = Calendar.list_events()
    assert [%{url: "https://example.com/feed.xml"}] = Sources.list_sources()
    assert [%{name: "local"}] = Providers.list_providers()

    assert %{memories: %{updated: 2}, calendar_events: %{updated: 1}} =
             Migration.import_all(legacy_root: root, library_root: library_root)

    assert length(Memory.list_memories()) == 2
    assert length(Calendar.list_events()) == 1
    assert length(Sources.list_sources()) == 1
    assert length(Providers.list_providers()) == 1
  end

  test "indexes legacy raw markdown and reports idempotently", %{library_root: library_root} do
    raw_path = Path.join([library_root, "raw", "2026-05-07", "story.md"])
    report_path = Path.join([library_root, "reports", "2026-05-07", "story-report.md"])

    File.mkdir_p!(Path.dirname(raw_path))
    File.mkdir_p!(Path.dirname(report_path))

    File.write!(raw_path, """
    ---
    url: "https://example.com/story"
    name: "Story"
    tags: ["legacy", "raw"]
    ---

    # Story

    Body text.
    """)

    File.write!(report_path, """
    ---
    source_file: "story.md"
    url: "https://example.com/story"
    model: "llama3"
    tags: ["report"]
    ---

    # Report

    Summary text.
    """)

    assert %{raw_documents: %{created: 1}, reports: %{created: 1}} =
             Migration.import_all(
               legacy_root: Path.dirname(library_root),
               library_root: library_root
             )

    assert [%{artifact_path: "raw/2026-05-07/story.md", name: "Story"}] =
             Library.list_documents()

    assert [%{artifact_path: "reports/2026-05-07/story-report.md", model: "llama3"}] =
             Library.list_reports()

    assert %{raw_documents: %{updated: 1}, reports: %{updated: 1}} =
             Migration.import_all(
               legacy_root: Path.dirname(library_root),
               library_root: library_root
             )

    assert length(Library.list_documents()) == 1
    assert length(Library.list_reports()) == 1
  end
end
