defmodule BusterClaw.Scheduler do
  @moduledoc "Scheduler job management and manual execution helpers."

  import Ecto.Changeset
  import Ecto.Query

  alias BusterClaw.{Analysis, Automation, Ingest, Integrations, Library, Repo, Sources, Workflow}
  alias BusterClaw.Automation.SchedulerJob
  alias BusterClaw.Scheduler.Cron

  @job_fields ~w(job_id type cron enabled custom_cmd deliver_to last_run_at next_run_at last_error)a

  def list_jobs do
    SchedulerJob
    |> order_by([job], asc: job.job_id)
    |> Repo.all()
  end

  def get_job!(id), do: Automation.get_scheduler_job!(id)

  def create_job(attrs) do
    %SchedulerJob{}
    |> prepare_job_attrs(attrs)
    |> case do
      {:ok, attrs} -> Automation.create_scheduler_job(attrs)
      {:error, changeset} -> {:error, changeset}
    end
  end

  def update_job(%SchedulerJob{} = job, attrs) do
    job
    |> prepare_job_attrs(attrs)
    |> case do
      {:ok, attrs} -> Automation.update_scheduler_job(job, attrs)
      {:error, changeset} -> {:error, changeset}
    end
  end

  def delete_job(%SchedulerJob{} = job), do: Automation.delete_scheduler_job(job)

  def change_job(%SchedulerJob{} = job \\ %SchedulerJob{}, attrs \\ %{}) do
    SchedulerJob.changeset(job, attrs)
  end

  def ensure_next_runs(now \\ timestamp()) do
    SchedulerJob
    |> where([job], job.enabled == true and is_nil(job.next_run_at))
    |> Repo.all()
    |> Enum.map(&schedule_next(&1, now))
  end

  def list_due_jobs(now \\ timestamp()) do
    SchedulerJob
    |> where(
      [job],
      job.enabled == true and not is_nil(job.next_run_at) and job.next_run_at <= ^now
    )
    |> order_by([job], asc: job.next_run_at, asc: job.job_id)
    |> Repo.all()
  end

  def run_due(now \\ timestamp()) do
    now
    |> list_due_jobs()
    |> Enum.map(fn job -> {job, run_now(job, now)} end)
  end

  def run_now(id) when is_binary(id) or is_integer(id), do: id |> get_job!() |> run_now()

  def run_now(%SchedulerJob{} = job, started_at \\ timestamp()) do
    case execute(job) do
      {:ok, summary} ->
        job
        |> finish_run_attrs(started_at, nil)
        |> then(&Automation.update_scheduler_job(job, &1))

        {:ok, summary}

      {:error, reason} ->
        error = bounded(inspect(reason))

        job
        |> finish_run_attrs(started_at, error)
        |> then(&Automation.update_scheduler_job(job, &1))

        {:error, reason}
    end
  end

  def schedule_next(%SchedulerJob{} = job, from \\ timestamp()) do
    case next_run_attrs(job, from) do
      {:ok, attrs} -> Automation.update_scheduler_job(job, attrs)
      {:error, attrs} -> Automation.update_scheduler_job(job, attrs)
    end
  end

  defp execute(%SchedulerJob{type: "ingest"} = job) do
    summary = Sources.list_sources() |> Ingest.ingest_sources()
    record_event(job, "scheduler.ingest", "Scheduler ingest run completed", summary)
    {:ok, summary}
  end

  defp execute(%SchedulerJob{type: "analyze"} = job) do
    case run_analysis_pipeline() do
      {:ok, summary} ->
        record_event(job, "scheduler.analyze", "Scheduler analyze run completed", summary)
        {:ok, summary}

      {:error, summary} ->
        record_event(job, "scheduler.analyze.failed", "Scheduler analyze run failed", summary)
        {:error, summary}
    end
  end

  defp execute(%SchedulerJob{type: "integrations_poll"} = job) do
    results = Integrations.poll_all(trigger: "scheduler")
    {ok_count, error_count} = Enum.reduce(results, {0, 0}, &count_integration_result/2)

    summary = %{
      status: "ok",
      ok: ok_count,
      errors: error_count,
      runs: Enum.map(results, &integration_run_summary/1)
    }

    record_event(
      job,
      "scheduler.integrations_poll",
      "Scheduler integration poll completed",
      summary
    )

    {:ok, summary}
  end

  defp execute(%SchedulerJob{type: "monitoring_brief"} = job),
    do: run_monitoring_brief(job, "monitoring_brief", "scheduler monitoring brief")

  defp execute(%SchedulerJob{type: "digest"} = job),
    do: run_monitoring_brief(job, "digest", "scheduler digest")

  defp execute(%SchedulerJob{type: "custom"} = job) do
    summary = %{
      status: "placeholder",
      custom_cmd: job.custom_cmd,
      message: "Custom scheduler commands are recorded but not executed yet."
    }

    record_event(job, "scheduler.custom", "Scheduler custom placeholder completed", summary)
    {:ok, summary}
  end

  defp execute(%SchedulerJob{type: "full"} = job) do
    ingest_summary = Sources.list_sources() |> Ingest.ingest_sources()

    case run_analysis_pipeline() do
      {:ok, analysis_summary} ->
        summary = full_summary(ingest_summary, analysis_summary)

        case full_result(summary) do
          {:ok, summary} ->
            record_event(job, "scheduler.full", "Scheduler full run completed", summary)
            {:ok, summary}

          {:error, summary} ->
            record_event(job, "scheduler.full.failed", "Scheduler full run failed", summary)
            {:error, summary}
        end

      {:error, analysis_summary} ->
        summary = full_summary(ingest_summary, analysis_summary)
        record_event(job, "scheduler.full.failed", "Scheduler full run failed", summary)
        {:error, summary}
    end
  end

  defp execute(%SchedulerJob{type: type}), do: {:error, {:unsupported_scheduler_type, type}}

  defp run_monitoring_brief(job, type, window) do
    case Integrations.generate_monitoring_brief(monitoring_brief_options(job, window)) do
      {:ok, report} ->
        summary = %{
          status: "ok",
          report_id: report.id,
          artifact_path: report.artifact_path
        }

        record_event(
          job,
          "scheduler.#{type}",
          "Scheduler #{scheduler_label(type)} completed",
          summary
        )

        {:ok, summary}

      {:error, reason} ->
        record_event(
          job,
          "scheduler.#{type}.failed",
          "Scheduler #{scheduler_label(type)} failed",
          %{
            status: "error",
            error: inspect(reason)
          }
        )

        {:error, reason}
    end
  end

  defp monitoring_brief_options(%SchedulerJob{} = job, window) do
    [window: window]
    |> maybe_put_provider_id(provider_id_from_custom_cmd(job.custom_cmd))
  end

  defp provider_id_from_custom_cmd(value) when value in [nil, ""], do: nil

  defp provider_id_from_custom_cmd(value) do
    value = String.trim(to_string(value))

    cond do
      Regex.match?(~r/^\d+$/, value) ->
        String.to_integer(value)

      match = Regex.run(~r/(?:^|\s)provider_id=(\d+)(?:\s|$)/, value) ->
        match |> List.last() |> String.to_integer()

      true ->
        nil
    end
  end

  defp maybe_put_provider_id(opts, nil), do: opts
  defp maybe_put_provider_id(opts, provider_id), do: Keyword.put(opts, :provider_id, provider_id)

  defp run_analysis_pipeline do
    queue_results =
      Library.list_documents()
      |> Enum.filter(&(&1.status == "fetched"))
      |> Enum.map(&queue_for_analysis/1)

    pending_count = pending_analysis_count()
    run_results = drain_pending_analysis(pending_count)
    summary = analysis_pipeline_summary(queue_results, pending_count, run_results)

    if summary.status == "ok", do: {:ok, summary}, else: {:error, summary}
  end

  defp queue_for_analysis(document) do
    case Analysis.queue_document(document) do
      {:ok, job} ->
        {:ok, job}

      {:error, reason} ->
        {:error,
         %{
           document_id: document.id,
           document_name: document.name || document.filename,
           error: error_text(reason)
         }}
    end
  end

  defp pending_analysis_count do
    Analysis.list_jobs()
    |> Enum.count(&(&1.status == "queued"))
  end

  defp drain_pending_analysis(0), do: []

  defp drain_pending_analysis(pending_count) do
    case Analysis.drain_pending(max_jobs: pending_count) do
      {:ok, results} -> results
      {:error, reason} -> [{:error, reason}]
    end
  end

  defp analysis_pipeline_summary(queue_results, pending_count, run_results) do
    queue_errors = queue_errors(queue_results)
    analysis_errors = analysis_errors(run_results)
    status = if queue_errors == [] and analysis_errors == [], do: "ok", else: "error"

    %{
      status: status,
      queued: Enum.count(queue_results, &match?({:ok, _job}, &1)),
      queue_errors: queue_errors,
      pending: pending_count,
      analyzed: Enum.count(run_results, &match?({:ok, _job}, &1)),
      analysis_errors: analysis_errors,
      jobs: Enum.map(run_results, &analysis_result_summary/1)
    }
  end

  defp queue_errors(queue_results) do
    Enum.flat_map(queue_results, fn
      {:ok, _job} -> []
      {:error, error} -> [error]
    end)
  end

  defp analysis_errors(run_results) do
    Enum.flat_map(run_results, fn
      {:ok, _job} -> []
      {:error, reason} -> [error_text(reason)]
    end)
  end

  defp analysis_result_summary({:ok, job}) do
    %{
      status: job.status,
      job_id: job.id,
      document_id: job.document_id,
      report_id: job.report_id
    }
  end

  defp analysis_result_summary({:error, reason}) do
    %{
      status: "error",
      error: error_text(reason)
    }
  end

  defp full_summary(ingest_summary, analysis_summary) do
    %{
      status: full_status(ingest_summary, analysis_summary),
      ingest: ingest_summary,
      analysis: analysis_summary
    }
  end

  defp full_result(%{status: "ok"} = summary), do: {:ok, summary}
  defp full_result(summary), do: {:error, summary}

  defp full_status(ingest_summary, analysis_summary) do
    cond do
      ingest_summary.errors != [] -> "error"
      analysis_summary.status != "ok" -> "error"
      true -> "ok"
    end
  end

  defp scheduler_label(type), do: String.replace(type, "_", " ")

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)

  defp prepare_job_attrs(%SchedulerJob{} = job, attrs) do
    attrs = normalize_job_attrs(attrs)
    cron = attr_value(attrs, :cron, job.cron)
    enabled = attr_boolean(attrs, :enabled, default_enabled(job))

    cond do
      !enabled ->
        {:ok, attrs |> put_attr(:enabled, false) |> put_attr(:next_run_at, nil)}

      !present?(cron) ->
        {:error, cron_error_changeset(job, attrs, "can't be blank")}

      true ->
        case Cron.next_run(to_string(cron), timestamp()) do
          {:ok, next_run_at} ->
            attrs =
              attrs
              |> put_attr(:cron, to_string(cron))
              |> put_attr(:enabled, true)
              |> put_attr(:next_run_at, next_run_at)

            {:ok, attrs}

          {:error, _reason} ->
            {:error, cron_error_changeset(job, attrs, "is invalid")}
        end
    end
  end

  defp finish_run_attrs(%SchedulerJob{} = job, started_at, error) do
    base_attrs = %{last_run_at: started_at, last_error: error}

    case next_run_attrs(job, started_at) do
      {:ok, attrs} -> Map.merge(base_attrs, attrs)
      {:error, attrs} -> Map.merge(base_attrs, attrs)
    end
  end

  defp next_run_attrs(%SchedulerJob{enabled: false}, _from), do: {:ok, %{next_run_at: nil}}

  defp next_run_attrs(%SchedulerJob{} = job, from) do
    case Cron.next_run(job.cron, from) do
      {:ok, next_run_at} ->
        {:ok, %{next_run_at: next_run_at}}

      {:error, reason} ->
        {:error,
         %{
           enabled: false,
           next_run_at: nil,
           last_error: "Invalid cron expression #{inspect(job.cron)}: #{inspect(reason)}"
         }}
    end
  end

  defp cron_error_changeset(%SchedulerJob{} = job, attrs, message) do
    job
    |> SchedulerJob.changeset(attrs)
    |> add_error(:cron, message)
  end

  defp record_event(job, kind, message, metadata) do
    Workflow.create_runtime_event(%{
      kind: kind,
      message: message,
      metadata: Map.merge(%{job_id: job.job_id, scheduler_job_id: job.id}, stringify(metadata)),
      occurred_at: timestamp()
    })
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), inspect(value)} end)
  end

  defp count_integration_result({:ok, _run}, {ok_count, error_count}),
    do: {ok_count + 1, error_count}

  defp count_integration_result({:error, _run}, {ok_count, error_count}),
    do: {ok_count, error_count + 1}

  defp integration_run_summary({status, run}) do
    %{
      status: status,
      run_id: run.id,
      integration_id: run.integration_id,
      records_fetched: run.records_fetched,
      error: run.error
    }
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp normalize_job_attrs(attrs) do
    Map.new(@job_fields, fn field ->
      {field, attr_value(attrs, field, :__missing__)}
    end)
    |> Enum.reject(fn {_field, value} -> value == :__missing__ end)
    |> Map.new()
  end

  defp attr_value(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, to_string(key)) -> Map.get(attrs, to_string(key))
      true -> default
    end
  end

  defp attr_boolean(attrs, key, default) do
    attrs
    |> attr_value(key, default)
    |> normalize_boolean(default)
  end

  defp put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp default_enabled(%SchedulerJob{enabled: nil}), do: true
  defp default_enabled(%SchedulerJob{enabled: enabled}), do: enabled

  defp normalize_boolean(value, _default) when is_boolean(value), do: value
  defp normalize_boolean(value, _default) when is_integer(value), do: value != 0
  defp normalize_boolean(value, default) when value in [nil, ""], do: default

  defp normalize_boolean(value, default) when is_binary(value) do
    case String.downcase(value) do
      "true" -> true
      "1" -> true
      "yes" -> true
      "on" -> true
      "false" -> false
      "0" -> false
      "no" -> false
      "off" -> false
      _ -> default
    end
  end

  defp normalize_boolean(_value, default), do: default

  defp present?(value), do: value not in [nil, ""]

  defp bounded(text, limit \\ 8_000) do
    if String.length(text) > limit,
      do: String.slice(text, 0, limit) <> "\n[truncated]",
      else: text
  end
end
