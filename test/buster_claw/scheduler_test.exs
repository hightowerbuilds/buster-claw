defmodule BusterClaw.SchedulerTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Automation, Integrations, Library, Providers, Scheduler, Workflow}

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

  test "validates cron expressions and initializes next run time" do
    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "next-hour",
               type: "ingest",
               cron: "@hourly"
             })

    assert job.next_run_at

    assert {:error, changeset} =
             Scheduler.create_job(%{
               job_id: "bad-cron",
               type: "ingest",
               cron: "not a cron"
             })

    assert %{cron: [_]} = errors_on(changeset)
  end

  test "initializes next_run_at for imported enabled jobs" do
    assert {:ok, job} =
             Automation.create_scheduler_job(%{
               job_id: "imported",
               type: "custom",
               cron: "@daily",
               custom_cmd: "echo imported"
             })

    refute job.next_run_at

    assert [{:ok, updated}] = Scheduler.ensure_next_runs(~U[2026-05-26 10:00:00Z])
    assert updated.job_id == "imported"
    assert updated.next_run_at == ~U[2026-05-27 00:00:00Z]
  end

  test "run_due executes due jobs and advances next_run_at" do
    now = ~U[2026-05-26 10:00:00Z]

    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "due-custom",
               type: "custom",
               cron: "* * * * *",
               custom_cmd: "echo due"
             })

    assert {:ok, _job} =
             Automation.update_scheduler_job(job, %{next_run_at: DateTime.add(now, -60, :second)})

    assert [{%{job_id: "due-custom"}, {:ok, %{status: "placeholder"}}}] = Scheduler.run_due(now)

    updated = Scheduler.get_job!(job.id)
    assert updated.last_run_at == now
    assert updated.next_run_at == ~U[2026-05-26 10:01:00Z]
  end

  test "supervised runner ticks due jobs" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "runner-custom",
               type: "custom",
               cron: "* * * * *",
               custom_cmd: "echo runner"
             })

    assert {:ok, _job} =
             Automation.update_scheduler_job(job, %{next_run_at: DateTime.add(now, -60, :second)})

    runner_name = :"scheduler-runner-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {BusterClaw.Scheduler.Runner, name: runner_name, interval_ms: 60_000, autostart: false}
      )

    send(pid, :tick)
    _ = :sys.get_state(pid)

    assert Scheduler.get_job!(job.id).last_run_at

    GenServer.stop(pid)
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

  test "run_now analyze queues fetched documents and drains analysis" do
    stub_provider_response("## Summary\n\nScheduler analysis completed.")
    active_provider!("openai-scheduler-analysis")
    document = raw_document!("Scheduler Analysis")

    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "analyze-documents",
               type: "analyze",
               cron: "@hourly"
             })

    assert {:ok, summary} = Scheduler.run_now(job)
    assert summary.status == "ok"
    assert summary.queued == 1
    assert summary.pending == 1
    assert summary.analyzed == 1
    assert summary.queue_errors == []
    assert summary.analysis_errors == []
    assert [%{status: "done", document_id: document_id, report_id: report_id}] = summary.jobs
    assert document_id == document.id
    assert report_id
    assert Library.get_document!(document.id).status == "analyzed"
    assert [report] = Library.list_reports()
    assert report.id == report_id
  end

  test "run_now full ingests sources then drains analysis" do
    stub_provider_response("## Summary\n\nFull scheduler run completed.")
    active_provider!("openai-scheduler-full")
    document = raw_document!("Full Scheduler Run")

    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "full-workflow",
               type: "full",
               cron: "@daily"
             })

    assert {:ok, summary} = Scheduler.run_now(job)
    assert summary.status == "ok"
    assert summary.ingest == %{saved: 0, errors: []}
    assert summary.analysis.queued == 1
    assert summary.analysis.analyzed == 1
    assert [%{status: "done", document_id: document_id}] = summary.analysis.jobs
    assert document_id == document.id
    assert Library.get_document!(document.id).status == "analyzed"
    assert [_report] = Library.list_reports()
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

  test "run_now monitoring brief can override the provider" do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "override-model"
      assert body =~ "Operational Snapshot"

      Req.Test.json(conn, %{
        choices: [
          %{
            message: %{
              content: "## Executive summary\n\nThe override operations brief is ready."
            }
          }
        ]
      })
    end)

    active_provider!("active-provider")

    assert {:ok, override_provider} =
             Providers.create_provider(%{
               name: "override-provider",
               type: "openai",
               model: "override-model",
               api_key: "secret",
               active: false
             })

    raw_document!("Operational Snapshot")

    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "monitoring-brief-override",
               type: "monitoring_brief",
               cron: "@daily",
               custom_cmd: "provider_id=#{override_provider.id}"
             })

    assert {:ok, summary} = Scheduler.run_now(job)
    assert summary.status == "ok"

    assert [report] = Library.list_reports()
    assert report.id == summary.report_id
    assert report.provider_id == override_provider.id
    assert report.model == "override-model"
  end

  test "run_now digest generates a monitoring brief" do
    stub_provider_response(
      "## Executive summary\n\nThe scheduled digest is ready.",
      "scheduler digest"
    )

    active_provider!("openai-scheduler-digest")
    raw_document!("Digest Snapshot")

    assert {:ok, job} =
             Scheduler.create_job(%{
               job_id: "daily-digest",
               type: "digest",
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

  defp stub_provider_response(content, expected_body_text \\ nil) do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if expected_body_text do
        assert body =~ expected_body_text
      end

      Req.Test.json(conn, %{
        choices: [
          %{
            message: %{
              content: content
            }
          }
        ]
      })
    end)
  end

  defp active_provider!(name) do
    assert {:ok, provider} =
             Providers.create_provider(%{
               name: name,
               type: "openai",
               model: "gpt-5.4",
               api_key: "secret",
               active: true
             })

    provider
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
