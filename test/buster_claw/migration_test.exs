defmodule BusterClaw.MigrationTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Automation, Calendar, Library, Memory, Migration}

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

  test "imports legacy memory and calendar idempotently", %{
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

    assert %{memories: %{created: 2}, calendar_events: %{created: 1}} =
             Migration.import_all(legacy_root: root, library_root: library_root)

    assert length(Memory.list_memories()) == 2
    assert [%{event_id: "event-1"}] = Calendar.list_events()

    assert %{memories: %{updated: 2}, calendar_events: %{updated: 1}} =
             Migration.import_all(legacy_root: root, library_root: library_root)

    assert length(Memory.list_memories()) == 2
    assert length(Calendar.list_events()) == 1
  end

  test "imports legacy automation JSON files idempotently", %{
    root: root,
    library_root: library_root
  } do
    File.write!(
      Path.join(root, "mcp.json"),
      Jason.encode!(%{
        mcpServers: %{
          filesystem: %{
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem"],
            env: %{ROOT: "/tmp"}
          }
        }
      })
    )

    File.write!(
      Path.join(library_root, "delivery.json"),
      Jason.encode!(%{
        destinations: [
          %{
            name: "ops",
            type: "slack",
            url: "https://hooks.slack.com/services/test",
            chatId: "C123"
          }
        ]
      })
    )

    File.write!(
      Path.join(library_root, "hooks.json"),
      Jason.encode!(%{
        hooks: [
          %{
            name: "after-report",
            event: "post_report",
            type: "webhook",
            target: "https://example.com/hook"
          }
        ]
      })
    )

    File.write!(
      Path.join(library_root, "webhooks.json"),
      Jason.encode!(%{
        hooks: [
          %{
            name: "ingest-now",
            action: "command",
            secret: "secret"
          }
        ]
      })
    )

    File.write!(
      Path.join(library_root, "scheduler.json"),
      Jason.encode!(%{
        jobs: [
          %{
            id: "bad-cron",
            type: "custom",
            cron: "not a cron",
            customCmd: "echo legacy",
            deliverTo: "ops"
          }
        ]
      })
    )

    assert %{
             mcp_servers: %{created: 1},
             delivery_destinations: %{created: 1},
             hooks: %{created: 1},
             webhooks: %{created: 1},
             scheduler_jobs: %{created: 1}
           } = Migration.import_all(legacy_root: root, library_root: library_root)

    assert [%{name: "filesystem", args: %{"items" => ["-y", _]}}] =
             Automation.list_mcp_servers()

    assert [%{name: "ops", chat_id: "C123"}] = Automation.list_delivery_destinations()
    assert [%{name: "after-report", event: "post_report"}] = Automation.list_hooks()
    assert [%{name: "ingest-now", action: "command"}] = Automation.list_webhooks()

    assert [%{job_id: "bad-cron", enabled: false, last_error: last_error}] =
             Automation.list_scheduler_jobs()

    assert last_error =~ "Invalid legacy cron expression"

    assert %{
             mcp_servers: %{updated: 1},
             delivery_destinations: %{updated: 1},
             hooks: %{updated: 1},
             webhooks: %{updated: 1},
             scheduler_jobs: %{updated: 1}
           } = Migration.import_all(legacy_root: root, library_root: library_root)

    assert length(Automation.list_mcp_servers()) == 1
    assert length(Automation.list_delivery_destinations()) == 1
    assert length(Automation.list_hooks()) == 1
    assert length(Automation.list_webhooks()) == 1
    assert length(Automation.list_scheduler_jobs()) == 1
  end

  test "indexes legacy raw markdown idempotently", %{library_root: library_root} do
    raw_path = Path.join([library_root, "raw", "2026-05-07", "story.md"])
    File.mkdir_p!(Path.dirname(raw_path))

    File.write!(raw_path, """
    ---
    url: "https://example.com/story"
    name: "Story"
    tags: ["legacy", "raw"]
    ---

    # Story

    Body text.
    """)

    assert %{raw_documents: %{created: 1}} =
             Migration.import_all(
               legacy_root: Path.dirname(library_root),
               library_root: library_root
             )

    assert [%{artifact_path: "raw/2026-05-07/story.md", name: "Story"}] =
             Library.list_documents()

    assert %{raw_documents: %{updated: 1}} =
             Migration.import_all(
               legacy_root: Path.dirname(library_root),
               library_root: library_root
             )

    assert length(Library.list_documents()) == 1
  end
end
