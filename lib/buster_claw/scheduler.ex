defmodule BusterClaw.Scheduler do
  @moduledoc "Scheduler job management and manual execution helpers."

  import Ecto.Query

  alias BusterClaw.{Automation, Ingest, Library, Repo, Sources, Workflow}
  alias BusterClaw.Automation.SchedulerJob

  def list_jobs do
    SchedulerJob
    |> order_by([job], asc: job.job_id)
    |> Repo.all()
  end

  def get_job!(id), do: Automation.get_scheduler_job!(id)
  def create_job(attrs), do: Automation.create_scheduler_job(attrs)
  def update_job(%SchedulerJob{} = job, attrs), do: Automation.update_scheduler_job(job, attrs)
  def delete_job(%SchedulerJob{} = job), do: Automation.delete_scheduler_job(job)

  def change_job(%SchedulerJob{} = job \\ %SchedulerJob{}, attrs \\ %{}) do
    SchedulerJob.changeset(job, attrs)
  end

  def run_now(id) when is_binary(id) or is_integer(id), do: id |> get_job!() |> run_now()

  def run_now(%SchedulerJob{} = job) do
    started_at = timestamp()

    case execute(job) do
      {:ok, summary} ->
        update_job(job, %{last_run_at: started_at, last_error: nil})
        {:ok, summary}

      {:error, reason} ->
        error = bounded(inspect(reason))
        update_job(job, %{last_run_at: started_at, last_error: error})
        {:error, reason}
    end
  end

  defp execute(%SchedulerJob{type: "ingest"} = job) do
    summary = Sources.list_sources() |> Ingest.ingest_sources()
    record_event(job, "scheduler.ingest", "Scheduler ingest run completed", summary)
    {:ok, summary}
  end

  defp execute(%SchedulerJob{type: "analyze"} = job) do
    documents = Library.list_documents()

    summary = %{
      queued: length(documents),
      status: "placeholder",
      message: "Analysis execution is not wired yet; #{length(documents)} documents were counted."
    }

    record_event(job, "scheduler.analyze", "Scheduler analyze placeholder completed", summary)
    {:ok, summary}
  end

  defp execute(%SchedulerJob{type: "custom"} = job) do
    summary = %{
      status: "placeholder",
      custom_cmd: job.custom_cmd,
      message: "Custom scheduler commands are recorded but not executed yet."
    }

    record_event(job, "scheduler.custom", "Scheduler custom placeholder completed", summary)
    {:ok, summary}
  end

  defp execute(%SchedulerJob{type: type} = job) when type in ["full", "digest"] do
    summary = %{
      status: "placeholder",
      type: type,
      message: "#{type} scheduler jobs are recorded but not executed yet."
    }

    record_event(job, "scheduler.#{type}", "Scheduler #{type} placeholder completed", summary)
    {:ok, summary}
  end

  defp execute(%SchedulerJob{type: type}), do: {:error, {:unsupported_scheduler_type, type}}

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

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp bounded(text, limit \\ 8_000) do
    if String.length(text) > limit,
      do: String.slice(text, 0, limit) <> "\n[truncated]",
      else: text
  end
end
