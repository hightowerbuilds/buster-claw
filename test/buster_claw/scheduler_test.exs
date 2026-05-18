defmodule BusterClaw.SchedulerTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Integrations, Library, Providers, Scheduler, Workflow}

  setup do
    Req.Test.verify_on_exit!()

    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-scheduler-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, previous)
      File.rm_rf(root)
    end)

    :ok
  end

  test "manages scheduler jobs through a focused context" do
    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "daily-ingest",
               type: "ingest",
               cron: "0 8 * * *"
             })

    assert [^job] = Scheduler.list_jobs()

    assert {:ok, job} = Scheduler.update_job(job, %{enabled: false})
    refute job.enabled

    assert {:ok, _job} = Scheduler.delete_job(job)
    assert [] = Scheduler.list_jobs()
  end

  test "run_now records custom placeholders without executing commands" do
    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "custom-placeholder",
               type: "custom",
               cron: "@daily",
               custom_cmd: "exit 42"
             })

    assert {:ok, summary} = Scheduler.run_now(job)
    assert summary.status == "placeholder"
    assert summary.custom_cmd == "exit 42"

    updated = Scheduler.get_job!(job.id)
    assert updated.last_run_at
    refute updated.last_error

    assert [event] = Workflow.list_runtime_events()
    assert event.kind == "scheduler.custom"
    assert event.metadata["job_id"] == "custom-placeholder"
  end

  test "run_now ingest succeeds with no configured sources" do
    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "empty-ingest",
               type: "ingest",
               cron: "@hourly"
             })

    assert {:ok, %{saved: 0, errors: []}} = Scheduler.run_now(job)
    assert Scheduler.get_job!(job.id).last_run_at
  end

  test "run_now can poll integrations" do
    {:ok, _integration} =
      Integrations.create_integration(%{
        name: "disabled-github",
        service_type: "github",
        enabled: false,
        config_text: ~s({"owner":"acme","repo":"checkout"})
      })

    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "poll-integrations",
               type: "integrations_poll",
               cron: "@hourly"
             })

    assert {:ok, summary} = Scheduler.run_now(job)
    assert summary.status == "ok"
    assert summary.ok == 0
    assert summary.errors == 1
    assert [run_summary] = summary.runs
    assert run_summary.status == :error

    assert [run] = Integrations.list_runs()
    assert run.trigger == "scheduler"
    assert run.error == "Integration is disabled"
  end

  test "run_now can generate a monitoring brief" do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "Operational Snapshot"

      Req.Test.json(conn, %{
        choices: [
          %{
            message: %{
              content: "## Executive summary\n\nThe operations brief is ready."
            }
          }
        ]
      })
    end)

    {:ok, _provider} =
      Providers.create_provider(%{
        name: "openai",
        type: "openai",
        model: "gpt-5.4",
        api_key: "secret",
        active: true
      })

    raw_document!("Operational Snapshot")

    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "monitoring-brief",
               type: "monitoring_brief",
               cron: "@daily"
             })

    assert {:ok, summary} = Scheduler.run_now(job)
    assert summary.status == "ok"
    assert summary.report_id
    assert summary.artifact_path =~ "monitoring-brief"
    assert [report] = Library.list_reports()
    assert report.id == summary.report_id

    updated = Scheduler.get_job!(job.id)
    assert updated.last_run_at
    refute updated.last_error
  end

  test "run_now records monitoring brief errors on the job" do
    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "empty-monitoring-brief",
               type: "monitoring_brief",
               cron: "@daily"
             })

    assert {:error, :no_integration_documents} = Scheduler.run_now(job)
    updated = Scheduler.get_job!(job.id)
    assert updated.last_run_at
    assert updated.last_error =~ "no_integration_documents"
  end

  defp raw_document!(name) do
    filename =
      name
      |> String.downcase()
      |> String.replace(" ", "-")
      |> Kernel.<>(".md")

    assert {:ok, document} =
             Library.save_raw_document(%{
               date: ~D[2026-05-18],
               filename: filename,
               name: name,
               source_url: "https://example.com/#{filename}",
               tags: ["integration", "github", "activity"],
               content: "# #{name}\n\nImportant scheduler source material."
             })

    document
  end
end
