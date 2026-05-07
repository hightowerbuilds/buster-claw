defmodule BusterClaw.LibraryWorkflowTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Automation, Library, Providers, Sources, Workflow}

  test "documents and reports can point to markdown artifact paths" do
    assert {:ok, source} = Sources.create_source(%{url: "https://example.com/a", type: "article"})

    assert {:ok, provider} =
             Providers.create_provider(%{name: "local", type: "ollama", model: "llama3"})

    assert {:ok, document} =
             Library.create_document(%{
               source_id: source.id,
               filename: "example.md",
               artifact_path: "Library/raw/2026-05-07/example.md",
               date: ~D[2026-05-07],
               source_url: source.url,
               content_hash: "abc123",
               status: "fetched"
             })

    assert {:ok, report} =
             Library.create_report(%{
               document_id: document.id,
               provider_id: provider.id,
               filename: "report-example.md",
               artifact_path: "Library/reports/2026-05-07/report-example.md",
               source_file: document.filename,
               source_url: source.url,
               model: provider.model,
               generated_at: ~U[2026-05-07 15:30:00Z]
             })

    assert [^document] = Library.list_documents()
    assert [^report] = Library.list_reports()

    assert {:error, changeset} =
             Library.create_document(%{
               filename: "example.md",
               artifact_path: "Library/raw/2026-05-07/example.md",
               status: "fetched"
             })

    assert %{artifact_path: [_]} = errors_on(changeset)
  end

  test "workflow records persist job, delivery, hook, and runtime state" do
    now = ~U[2026-05-07 16:00:00Z]

    assert {:ok, document} =
             Library.create_document(%{
               filename: "a.md",
               artifact_path: "Library/raw/2026-05-07/a.md"
             })

    assert {:ok, report} =
             Library.create_report(%{
               filename: "r.md",
               artifact_path: "Library/reports/2026-05-07/r.md"
             })

    assert {:ok, destination} =
             Automation.create_delivery_destination(%{name: "discord", type: "discord"})

    assert {:ok, hook} =
             Automation.create_hook(%{
               name: "audit",
               event: "on_error",
               type: "shell",
               target: "cat"
             })

    assert {:ok, analysis_job} =
             Workflow.create_analysis_job(%{
               document_id: document.id,
               report_id: report.id,
               status: "done",
               progress: 100,
               model: "llama3",
               started_at: now,
               finished_at: now
             })

    assert {:ok, delivery_attempt} =
             Workflow.create_delivery_attempt(%{
               delivery_destination_id: destination.id,
               report_id: report.id,
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
               payload: %{"phase" => "analysis"}
             })

    assert {:ok, runtime_event} =
             Workflow.create_runtime_event(%{
               kind: "migration",
               message: "import started",
               metadata: %{"dry_run" => true},
               occurred_at: now
             })

    assert [^analysis_job] = Workflow.list_analysis_jobs()
    assert [^delivery_attempt] = Workflow.list_delivery_attempts()
    assert [^hook_run] = Workflow.list_hook_runs()
    assert [^runtime_event] = Workflow.list_runtime_events()
  end
end
