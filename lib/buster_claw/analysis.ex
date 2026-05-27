defmodule BusterClaw.Analysis do
  @moduledoc "Queue and runner for document analysis jobs and report artifacts."

  import Ecto.Query

  alias BusterClaw.{Delivery, Hooks, Intentions}
  alias BusterClaw.Library
  alias BusterClaw.Library.{Artifact, Document, Frontmatter, Report}
  alias BusterClaw.Providers
  alias BusterClaw.Providers.Provider
  alias BusterClaw.Repo
  alias BusterClaw.Workflow.AnalysisJob

  @topic "analysis"
  @queued_statuses ["queued", "analyzing"]

  def topic, do: @topic

  def subscribe do
    Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)
  end

  def list_jobs do
    AnalysisJob
    |> order_by([j],
      asc: fragment("case ? when 'analyzing' then 0 when 'queued' then 1 else 2 end", j.status),
      desc: j.inserted_at
    )
    |> preload([:document, :report, :provider])
    |> Repo.all()
  end

  def list_reports do
    Report
    |> order_by([r], desc: r.generated_at, desc: r.inserted_at)
    |> preload([:document, :provider])
    |> Repo.all()
  end

  def queue_document(document_or_id, attrs \\ %{})

  def queue_document(id, attrs) when is_binary(id) or is_integer(id) do
    id
    |> Library.get_document!()
    |> queue_document(attrs)
  end

  def queue_document(%Document{} = document, attrs) do
    attrs = normalize_attrs(attrs)

    case active_job_for_document(document.id) do
      nil -> insert_queued_job(document, attrs)
      %AnalysisJob{} = job -> {:ok, preload_job(job)}
    end
  end

  def run_pending(opts \\ []) do
    limit = Keyword.get(opts, :limit, 1)

    pending_jobs(limit)
    |> Enum.map(&run_job(&1, opts))
  end

  def drain_pending(opts \\ []) do
    max_jobs = Keyword.get(opts, :max_jobs, 100)
    drain_pending([], max_jobs, opts)
  end

  def run_job(job_or_id, opts \\ [])

  def run_job(id, opts) when is_binary(id) or is_integer(id) do
    AnalysisJob
    |> Repo.get!(id)
    |> run_job(opts)
  end

  def run_job(%AnalysisJob{} = job, opts) do
    job = preload_job(job)

    with {:ok, provider} <- provider_for_job(job, opts),
         {:ok, job} <- start_job(job, provider),
         {:ok, body} <- Library.read_raw_document(job.document),
         {:ok, content} <-
           call_provider(provider, Intentions.analysis_messages(job.document, body)),
         {:ok, report} <- save_report(job.document, provider, content),
         {:ok, job} <- finish_job(job, report) do
      run_report_side_effects(job, report, opts)
      {:ok, preload_job(job)}
    else
      {:error, reason} ->
        fail_job(job, reason)
    end
  end

  defp drain_pending(results, 0, _opts), do: {:ok, Enum.reverse(results)}

  defp drain_pending(results, remaining, opts) do
    case pending_jobs(1) do
      [] ->
        {:ok, Enum.reverse(results)}

      [job] ->
        drain_pending([run_job(job, opts) | results], remaining - 1, opts)
    end
  end

  defp active_job_for_document(document_id) do
    Repo.one(
      from j in AnalysisJob,
        where: j.document_id == ^document_id and j.status in ^@queued_statuses,
        order_by: [desc: j.inserted_at],
        limit: 1
    )
  end

  defp insert_queued_job(%Document{} = document, attrs) do
    provider = provider_from_attrs(attrs) || Providers.active_provider()

    Repo.transaction(fn ->
      {:ok, _document} = Library.update_document(document, %{status: "queued"})

      %AnalysisJob{}
      |> AnalysisJob.changeset(%{
        document_id: document.id,
        provider_id: provider && provider.id,
        status: "queued",
        progress: 0,
        model: Map.get(attrs, :model) || provider_model(provider)
      })
      |> Repo.insert!()
    end)
    |> case do
      {:ok, job} -> broadcast_job(:queued, job)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_job(job, provider) do
    now = now()

    Repo.transaction(fn ->
      {:ok, _document} = Library.update_document(job.document, %{status: "analyzing"})

      job
      |> AnalysisJob.changeset(%{
        provider_id: provider.id,
        status: "analyzing",
        progress: 10,
        model: provider.model,
        error: nil,
        started_at: now
      })
      |> Repo.update!()
    end)
    |> case do
      {:ok, job} -> broadcast_job(:started, job)
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_job(job, report) do
    now = now()

    Repo.transaction(fn ->
      {:ok, _document} = Library.update_document(job.document, %{status: "analyzed"})

      job
      |> AnalysisJob.changeset(%{
        report_id: report.id,
        status: "done",
        progress: 100,
        finished_at: now
      })
      |> Repo.update!()
    end)
    |> case do
      {:ok, job} -> broadcast_job(:done, job)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fail_job(job, reason) do
    now = now()
    error = error_to_string(reason)

    Repo.transaction(fn ->
      document = Repo.get!(Document, job.document_id)
      {:ok, _document} = Library.update_document(document, %{status: "failed"})

      job
      |> AnalysisJob.changeset(%{
        status: "failed",
        progress: 100,
        error: error,
        finished_at: now
      })
      |> Repo.update!()
    end)
    |> case do
      {:ok, failed_job} ->
        broadcast_job(:failed, failed_job)
        {:error, error}

      {:error, tx_reason} ->
        {:error, tx_reason}
    end
  end

  defp save_report(document, provider, content) do
    generated_at = now()
    filename = report_filename(document, generated_at)
    dir = Artifact.reports_date_dir(DateTime.to_date(generated_at))
    path = Artifact.safe_join!(dir, [filename])
    :ok = File.mkdir_p!(dir)

    metadata = %{
      source_file: document.filename,
      source_url: document.source_url,
      provider_name: provider.name,
      model: provider.model,
      generated_at: DateTime.to_iso8601(generated_at)
    }

    bytes =
      Frontmatter.build(%{
        "document_id" => document.id,
        "source_file" => document.filename,
        "source_url" => document.source_url,
        "provider" => provider.name,
        "model" => provider.model,
        "generated_at" => DateTime.to_iso8601(generated_at)
      }) <>
        Intentions.report_markdown(document, content, metadata)

    File.write!(path, bytes)

    Library.create_report(%{
      document_id: document.id,
      provider_id: provider.id,
      filename: filename,
      artifact_path: Artifact.relative_to_root(path),
      source_file: document.filename,
      source_url: document.source_url,
      model: provider.model,
      tags: %{
        "analysis" => %{
          "document_id" => document.id,
          "provider" => provider.name,
          "model" => provider.model
        }
      },
      generated_at: generated_at
    })
  end

  defp run_report_side_effects(job, report, opts) do
    payload = report_payload(job, report)
    hook_opts = side_effect_options(opts, :hook_options, :hook_req_options)

    Enum.each(["post_analysis", "post_report"], fn event ->
      Hooks.execute_event(event, Map.put(payload, "event", event), hook_opts)
    end)

    opts
    |> side_effect_options(:delivery_options, :delivery_req_options)
    |> Keyword.put(:report_id, report.id)
    |> then(&Delivery.dispatch_all(payload, &1))

    :ok
  rescue
    _error -> :ok
  end

  defp report_payload(job, report) do
    document = job.document
    provider = job.provider

    %{
      "title" => report_title(document, report),
      "body" => report_body(document, report),
      "analysis_job_id" => job.id,
      "document_id" => document && document.id,
      "document_name" => document && document.name,
      "report_id" => report.id,
      "report_filename" => report.filename,
      "report_path" => report.artifact_path,
      "source_file" => report.source_file,
      "source_url" => report.source_url,
      "provider_id" => provider && provider.id,
      "provider_name" => provider && provider.name,
      "model" => report.model,
      "generated_at" => iso8601(report.generated_at)
    }
  end

  defp report_title(document, report) do
    name = (document && document.name) || report.source_file || report.filename
    "Report ready: #{name}"
  end

  defp report_body(document, report) do
    source = report.source_url || (document && document.source_url) || "local document"

    [
      "Buster Claw generated a report.",
      "Report: #{report.artifact_path}",
      "Source: #{source}",
      "Model: #{report.model || "unknown"}"
    ]
    |> Enum.join("\n")
  end

  defp side_effect_options(opts, option_key, req_options_key) do
    options = Keyword.get(opts, option_key, [])
    req_options = Keyword.get(opts, req_options_key, Keyword.get(opts, :req_options))

    if is_nil(req_options) do
      options
    else
      Keyword.put_new(options, :req_options, req_options)
    end
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_datetime), do: nil

  defp call_provider(provider, messages) do
    chunks = Agent.start_link(fn -> [] end)

    with {:ok, pid} <- chunks,
         :ok <-
           Providers.chat(provider, messages, fn chunk -> Agent.update(pid, &[chunk | &1]) end) do
      content = pid |> Agent.get(&Enum.reverse/1) |> Enum.join()
      Agent.stop(pid)
      {:ok, content}
    else
      {:error, reason} ->
        with {:ok, pid} <- chunks, do: Agent.stop(pid)
        {:error, reason}
    end
  end

  defp provider_for_job(job, opts) do
    cond do
      provider = Keyword.get(opts, :provider) ->
        {:ok, provider}

      job.provider ->
        {:ok, job.provider}

      provider = Providers.active_provider() ->
        {:ok, provider}

      true ->
        {:error, :no_active_provider}
    end
  end

  defp pending_jobs(limit) do
    AnalysisJob
    |> where([j], j.status == "queued")
    |> order_by([j], asc: j.inserted_at)
    |> limit(^limit)
    |> preload([:document, :provider])
    |> Repo.all()
  end

  defp broadcast_job(event, job) do
    job = preload_job(job)
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:analysis_job, event, job})
    {:ok, job}
  end

  defp preload_job(job), do: Repo.preload(job, [:document, :report, :provider], force: true)

  defp provider_from_attrs(attrs) do
    case Map.get(attrs, :provider_id) do
      nil -> nil
      provider_id -> Providers.get_provider!(provider_id)
    end
  end

  defp provider_model(nil), do: nil
  defp provider_model(%Provider{} = provider), do: provider.model

  defp report_filename(document, generated_at) do
    stamp = generated_at |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9TZ]/, "")
    base = document.name || Path.rootname(document.filename)

    base =
      base
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._-]+/, "-")
      |> String.trim("-")

    "analysis-#{document.id}-#{base}-#{stamp}.md"
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    Enum.into(attrs, %{}, fn
      {"provider_id", value} -> {:provider_id, value}
      {"model", value} -> {:model, value}
      pair -> pair
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp error_to_string(reason) when is_binary(reason), do: reason
  defp error_to_string(reason), do: inspect(reason)
end
