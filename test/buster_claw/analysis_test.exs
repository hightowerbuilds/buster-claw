defmodule BusterClaw.AnalysisTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Analysis, Delivery, Hooks, Library, Providers, Workflow}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-analysis-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, root)
    Req.Test.verify_on_exit!()

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, previous)
      File.rm_rf(root)
    end)

    :ok
  end

  test "queues a document once and broadcasts the queued job" do
    Analysis.subscribe()
    document = raw_document!("Queue Me")

    assert {:ok, job} = Analysis.queue_document(document)
    assert job.status == "queued"
    assert job.progress == 0
    assert Library.get_document!(document.id).status == "queued"
    assert_receive {:analysis_job, :queued, %{id: job_id}}
    assert job_id == job.id

    assert {:ok, duplicate} = Analysis.queue_document(document)
    assert duplicate.id == job.id
    assert [_job] = Workflow.list_analysis_jobs()
  end

  test "runs pending jobs, saves a report artifact, and marks document analyzed" do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      Req.Test.json(conn, %{
        choices: [
          %{
            message: %{
              content: "## Summary\n\nThis document has a clear launch signal."
            }
          }
        ]
      })
    end)

    {:ok, provider} =
      Providers.create_provider(%{
        name: "openai",
        type: "openai",
        model: "gpt-5.4",
        api_key: "secret",
        active: true
      })

    document = raw_document!("Run Me")
    {:ok, queued_job} = Analysis.queue_document(document)

    assert [{:ok, job}] = Analysis.run_pending()
    assert job.id == queued_job.id
    assert job.status == "done"
    assert job.progress == 100
    assert job.provider_id == provider.id
    assert job.report_id
    assert Library.get_document!(document.id).status == "analyzed"

    report = Library.get_report!(job.report_id)
    assert report.document_id == document.id
    assert report.provider_id == provider.id
    assert report.model == "gpt-5.4"
    assert report.tags["analysis"]["document_id"] == document.id

    report_path = Library.absolute_artifact_path(report.artifact_path)
    assert File.exists?(report_path)
    assert File.read!(report_path) =~ "This document has a clear launch signal."
  end

  test "runs post-report hooks and delivery after report generation" do
    test_pid = self()

    Req.Test.stub(BusterClaw.AnalysisHookHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:hook_request, conn.request_path, body})
      Req.Test.json(conn, %{ok: true})
    end)

    Req.Test.stub(BusterClaw.AnalysisDeliveryHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:delivery_request, conn.request_path, body})
      Req.Test.json(conn, %{ok: true})
    end)

    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      Req.Test.json(conn, %{
        choices: [
          %{
            message: %{
              content: "## Summary\n\nSide effects report."
            }
          }
        ]
      })
    end)

    {:ok, _provider} =
      Providers.create_provider(%{
        name: "openai-side-effects",
        type: "openai",
        model: "gpt-5.4",
        api_key: "secret",
        active: true
      })

    {:ok, _post_analysis} =
      Hooks.create_hook(%{
        name: "after-analysis",
        event: "post_analysis",
        type: "webhook",
        target: "https://example.com/hooks/post-analysis"
      })

    {:ok, _post_report} =
      Hooks.create_hook(%{
        name: "after-report",
        event: "post_report",
        type: "webhook",
        target: "https://example.com/hooks/post-report"
      })

    {:ok, _destination} =
      Delivery.create_destination(%{
        name: "team-slack",
        type: "slack",
        url: "https://example.com/delivery/report"
      })

    document = raw_document!("Side Effects")
    {:ok, queued_job} = Analysis.queue_document(document)

    assert {:ok, job} =
             Analysis.run_job(queued_job,
               hook_req_options: [plug: {Req.Test, BusterClaw.AnalysisHookHTTP}],
               delivery_req_options: [plug: {Req.Test, BusterClaw.AnalysisDeliveryHTTP}]
             )

    assert job.status == "done"
    assert job.report_id

    assert_receive {:hook_request, "/hooks/post-analysis", post_analysis_body}
    assert post_analysis_body =~ "post_analysis"
    assert post_analysis_body =~ "#{job.report_id}"

    assert_receive {:hook_request, "/hooks/post-report", post_report_body}
    assert post_report_body =~ "post_report"
    assert post_report_body =~ "#{job.report_id}"

    assert_receive {:delivery_request, "/delivery/report", delivery_body}
    assert delivery_body =~ "Report ready: Side Effects"
    assert delivery_body =~ "#{job.report_id}"

    assert Enum.map(Workflow.list_hook_runs(), & &1.event) |> Enum.sort() == [
             "post_analysis",
             "post_report"
           ]

    assert [attempt] = Workflow.list_delivery_attempts()
    assert attempt.status == "sent"
    assert attempt.report_id == job.report_id
    assert attempt.title == "Report ready: Side Effects"
  end

  test "drains queued jobs sequentially" do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      Req.Test.json(conn, %{message: %{content: "local report"}})
    end)

    {:ok, _provider} =
      Providers.create_provider(%{
        name: "ollama",
        type: "ollama",
        model: "llama3",
        active: true
      })

    first = raw_document!("First")
    second = raw_document!("Second")
    assert {:ok, _} = Analysis.queue_document(first)
    assert {:ok, _} = Analysis.queue_document(second)

    assert {:ok, [{:ok, _}, {:ok, _}]} = Analysis.drain_pending(max_jobs: 10)
    assert Enum.map(Analysis.list_jobs(), & &1.status) == ["done", "done"]
    assert length(Analysis.list_reports()) == 2
  end

  test "runs a specific queued job by id" do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      Req.Test.json(conn, %{
        choices: [
          %{
            message: %{
              content: "## Summary\n\nSpecific job completed."
            }
          }
        ]
      })
    end)

    {:ok, _provider} =
      Providers.create_provider(%{
        name: "openai-specific",
        type: "openai",
        model: "gpt-5.4",
        api_key: "secret",
        active: true
      })

    document = raw_document!("Specific Job")
    assert {:ok, queued_job} = Analysis.queue_document(document)

    assert {:ok, job} = Analysis.run_job(queued_job.id)
    assert job.id == queued_job.id
    assert job.status == "done"
    assert job.report_id
  end

  test "marks a job failed when no provider is available" do
    document = raw_document!("No Provider")
    assert {:ok, queued_job} = Analysis.queue_document(document)

    assert {:error, ":no_active_provider"} = Analysis.run_job(queued_job)
    [failed_job] = Workflow.list_analysis_jobs()
    assert failed_job.status == "failed"
    assert failed_job.error == ":no_active_provider"
    assert Library.get_document!(document.id).status == "failed"
  end

  defp raw_document!(name) do
    filename =
      name
      |> String.downcase()
      |> String.replace(" ", "-")
      |> Kernel.<>(".md")

    assert {:ok, document} =
             Library.save_raw_document(%{
               date: ~D[2026-05-07],
               filename: filename,
               name: name,
               source_url: "https://example.com/#{filename}",
               content: "# #{name}\n\nImportant source material."
             })

    document
  end
end
