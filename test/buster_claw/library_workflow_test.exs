defmodule BusterClaw.LibraryWorkflowTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Automation, Library, Workflow}

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

  test "workflow records persist delivery, hook, and runtime state" do
    now = ~U[2026-05-07 16:00:00Z]

    assert {:ok, destination} =
             Automation.create_delivery_destination(%{name: "discord", type: "discord"})

    assert {:ok, hook} =
             Automation.create_hook(%{
               name: "audit",
               event: "on_error",
               type: "shell",
               target: "cat"
             })

    assert {:ok, delivery_attempt} =
             Workflow.create_delivery_attempt(%{
               delivery_destination_id: destination.id,
               title: "Report",
               status: "sent",
               started_at: now,
               finished_at: now
             })

    assert {:ok, hook_run} =
             Workflow.create_hook_run(%{
               hook_id: hook.id,
               event: "on_error",
               type: "shell",
               started_at: now,
               success: true,
               payload: %{"phase" => "delivery"}
             })

    assert {:ok, runtime_event} =
             Workflow.create_runtime_event(%{
               kind: "migration",
               message: "import started",
               metadata: %{"dry_run" => true},
               occurred_at: now
             })

    assert [^delivery_attempt] = Workflow.list_delivery_attempts()
    assert [^hook_run] = Workflow.list_hook_runs()
    assert [^runtime_event] = Workflow.list_runtime_events()
  end
end
