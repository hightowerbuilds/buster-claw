defmodule BusterClaw.Integrations do
  @moduledoc "Service integrations that turn operational data into Library documents."

  import Ecto.Query

  alias BusterClaw.Intentions
  alias BusterClaw.Integrations.{GitHub, Integration, IntegrationRun, Sentry, Umami}
  alias BusterClaw.Library
  alias BusterClaw.Library.{Artifact, Frontmatter}
  alias BusterClaw.Providers
  alias BusterClaw.Repo

  @topic "integrations"
  @max_error 8_000

  def topic, do: @topic

  def subscribe do
    Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)
  end

  def list_integrations do
    Integration
    |> order_by([integration], asc: integration.service_type, asc: integration.name)
    |> Repo.all()
  end

  def get_integration!(id), do: Repo.get!(Integration, id)
  def get_by_name(name), do: Repo.get_by(Integration, name: name)

  def create_integration(attrs) do
    %Integration{}
    |> Integration.changeset(attrs)
    |> Repo.insert()
    |> broadcast_change(:created)
  end

  def update_integration(%Integration{} = integration, attrs) do
    integration
    |> Integration.changeset(attrs)
    |> Repo.update()
    |> broadcast_change(:updated)
  end

  def delete_integration(%Integration{} = integration) do
    integration
    |> Repo.delete()
    |> broadcast_change(:deleted)
  end

  def change_integration(%Integration{} = integration \\ %Integration{}, attrs \\ %{}) do
    attrs =
      if map_size(attrs) == 0 and integration.config_text in [nil, ""] do
        Map.put(attrs, :config_text, encode_config(integration.config || %{}))
      else
        attrs
      end

    Integration.changeset(integration, attrs)
  end

  def list_runs do
    IntegrationRun
    |> order_by([run], desc: run.started_at, desc: run.inserted_at)
    |> preload([:integration, :document])
    |> Repo.all()
  end

  def list_runs_for_integration(%Integration{} = integration) do
    IntegrationRun
    |> where([run], run.integration_id == ^integration.id)
    |> order_by([run], desc: run.started_at, desc: run.inserted_at)
    |> preload([:integration, :document])
    |> Repo.all()
  end

  def latest_documents(limit \\ 10) do
    Library.list_documents()
    |> Enum.filter(&integration_document?/1)
    |> Enum.take(limit)
  end

  def create_run(attrs) do
    %IntegrationRun{}
    |> IntegrationRun.changeset(attrs)
    |> Repo.insert()
    |> broadcast_run()
  end

  def poll_integration(integration_or_id, opts \\ [])

  def poll_integration(id, opts) when is_binary(id) or is_integer(id) do
    id
    |> get_integration!()
    |> poll_integration(opts)
  end

  def poll_integration(%Integration{enabled: false} = integration, opts) do
    now = timestamp()
    error = "Integration is disabled"

    {:ok, run} =
      create_run(%{
        integration_id: integration.id,
        trigger: trigger(opts),
        status: "error",
        records_fetched: 0,
        error: error,
        started_at: now,
        finished_at: now,
        metadata: %{"service_type" => integration.service_type}
      })

    {:ok, _integration} =
      update_integration(integration, %{
        last_run_at: now,
        last_status: "disabled",
        last_error: error
      })

    {:error, run}
  end

  def poll_integration(%Integration{} = integration, opts) do
    now = timestamp()

    case adapter_for(integration) do
      {:ok, adapter} ->
        poll_with_adapter(integration, adapter, now, opts)

      {:error, reason} ->
        error = bounded_error(error_message(reason))

        {:ok, run} =
          create_run(%{
            integration_id: integration.id,
            trigger: trigger(opts),
            status: "error",
            records_fetched: 0,
            error: error,
            started_at: now,
            finished_at: now,
            metadata: %{"service_type" => integration.service_type}
          })

        {:ok, _integration} =
          update_integration(integration, %{
            last_run_at: now,
            last_status: "error",
            last_error: error
          })

        {:error, run}
    end
  end

  defp poll_with_adapter(integration, adapter, started_at, opts) do
    result =
      with {:ok, items} <- adapter.fetch(integration, opts),
           {:ok, documents} <- save_snapshot_items(items) do
        {:ok, items, documents}
      end

    case result do
      {:ok, items, documents} ->
        document = List.first(documents)

        {:ok, run} =
          create_run(%{
            integration_id: integration.id,
            document_id: document && document.id,
            trigger: trigger(opts),
            status: "ok",
            records_fetched: length(items),
            error: nil,
            started_at: started_at,
            finished_at: timestamp(),
            metadata: %{
              "service_type" => integration.service_type,
              "documents" => Enum.map(documents, & &1.artifact_path)
            }
          })

        {:ok, _integration} =
          update_integration(integration, %{
            last_run_at: started_at,
            last_status: "ok",
            last_error: nil
          })

        {:ok, run}

      {:error, reason} ->
        error = bounded_error(error_message(reason))

        {:ok, run} =
          create_run(%{
            integration_id: integration.id,
            trigger: trigger(opts),
            status: "error",
            records_fetched: 0,
            error: error,
            started_at: started_at,
            finished_at: timestamp(),
            metadata: %{"service_type" => integration.service_type}
          })

        {:ok, _integration} =
          update_integration(integration, %{
            last_run_at: started_at,
            last_status: "error",
            last_error: error
          })

        {:error, run}
    end
  end

  defp save_snapshot_items(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, documents} ->
      case Library.save_raw_document(item) do
        {:ok, document} -> {:cont, {:ok, [document | documents]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, documents} -> {:ok, Enum.reverse(documents)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp adapter_for(%Integration{service_type: "umami"}), do: {:ok, Umami}
  defp adapter_for(%Integration{service_type: "sentry"}), do: {:ok, Sentry}
  defp adapter_for(%Integration{service_type: "github"}), do: {:ok, GitHub}

  defp adapter_for(%Integration{service_type: service_type}),
    do: {:error, {:unsupported_integration, service_type}}

  defp error_message({:unsupported_integration, service_type}),
    do: "Polling adapter for #{service_type} is not implemented yet."

  defp error_message(reason), do: inspect(reason)

  def poll_all(opts \\ []) do
    list_integrations()
    |> Enum.map(&poll_integration(&1, opts))
  end

  def handle_webhook(name_or_integration, headers, body, opts \\ [])

  def handle_webhook(name, headers, body, opts) when is_binary(name) do
    case get_by_name(name) do
      nil -> {:error, :not_found}
      integration -> handle_webhook(integration, headers, body, opts)
    end
  end

  def handle_webhook(%Integration{enabled: false} = integration, _headers, _body, opts) do
    now = timestamp()
    error = "Integration is disabled"

    {:ok, run} =
      create_run(%{
        integration_id: integration.id,
        trigger: trigger(Keyword.put(opts, :trigger, "webhook")),
        status: "error",
        records_fetched: 0,
        error: error,
        started_at: now,
        finished_at: now,
        metadata: %{"service_type" => integration.service_type}
      })

    {:ok, _integration} =
      update_integration(integration, %{
        last_run_at: now,
        last_status: "disabled",
        last_error: error
      })

    {:error, run}
  end

  def handle_webhook(%Integration{} = integration, headers, body, opts) do
    now = timestamp()

    result =
      with {:ok, adapter} <- adapter_for(integration),
           :ok <- adapter.verify_webhook(integration, headers, body),
           {:ok, items} <- adapter.normalize_webhook(integration, body),
           {:ok, documents} <- save_snapshot_items(items) do
        {:ok, items, documents}
      end

    case result do
      {:ok, items, documents} ->
        document = List.first(documents)

        {:ok, run} =
          create_run(%{
            integration_id: integration.id,
            document_id: document && document.id,
            trigger: trigger(Keyword.put(opts, :trigger, "webhook")),
            status: "ok",
            records_fetched: length(items),
            error: nil,
            started_at: now,
            finished_at: timestamp(),
            metadata: %{
              "service_type" => integration.service_type,
              "documents" => Enum.map(documents, & &1.artifact_path)
            }
          })

        {:ok, _integration} =
          update_integration(integration, %{last_run_at: now, last_status: "ok", last_error: nil})

        {:ok, run}

      {:error, reason} ->
        error = bounded_error(error_message(reason))

        {:ok, run} =
          create_run(%{
            integration_id: integration.id,
            trigger: trigger(Keyword.put(opts, :trigger, "webhook")),
            status: "error",
            records_fetched: 0,
            error: error,
            started_at: now,
            finished_at: timestamp(),
            metadata: %{"service_type" => integration.service_type}
          })

        {:ok, _integration} =
          update_integration(integration, %{
            last_run_at: now,
            last_status: "error",
            last_error: error
          })

        {:error, run}
    end
  end

  def generate_monitoring_brief(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    documents = latest_documents(limit)

    with false <- documents == [],
         {:ok, provider} <- active_provider(),
         {:ok, source_material} <- read_source_material(documents),
         {:ok, content} <-
           call_provider(provider, Intentions.monitoring_brief_messages(source_material, opts)),
         {:ok, report} <- save_monitoring_report(provider, documents, content) do
      {:ok, report}
    else
      true -> {:error, :no_integration_documents}
      {:error, reason} -> {:error, reason}
    end
  end

  defp trigger(opts), do: opts |> Keyword.get(:trigger, "manual") |> to_string()

  defp integration_document?(document) do
    "integration" in get_in(document.tags || %{}, ["items"])
  end

  defp active_provider do
    case Providers.active_provider() do
      nil -> {:error, :no_active_provider}
      provider -> {:ok, provider}
    end
  end

  defp read_source_material(documents) do
    documents
    |> Enum.reduce_while({:ok, []}, fn document, {:ok, acc} ->
      case Library.read_raw_document(document) do
        {:ok, body} -> {:cont, {:ok, [%{document: document, body: body} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp save_monitoring_report(provider, documents, content) do
    generated_at = timestamp()
    dir = Artifact.reports_date_dir(DateTime.to_date(generated_at))
    filename = monitoring_report_filename(generated_at)
    path = Artifact.safe_join!(dir, [filename])
    :ok = File.mkdir_p!(dir)

    metadata = %{
      provider_name: provider.name,
      model: provider.model,
      generated_at: DateTime.to_iso8601(generated_at),
      source_file: "#{length(documents)} integration snapshots",
      source_url: "local-library"
    }

    bytes =
      Frontmatter.build(%{
        "provider" => provider.name,
        "model" => provider.model,
        "generated_at" => DateTime.to_iso8601(generated_at),
        "source_documents" => Enum.map(documents, & &1.artifact_path),
        "tags" => ["monitoring", "brief", "consultation"]
      }) <>
        Intentions.monitoring_brief_markdown(content, metadata)

    File.write!(path, bytes)

    Library.create_report(%{
      provider_id: provider.id,
      filename: filename,
      artifact_path: Artifact.relative_to_root(path),
      source_file: metadata.source_file,
      source_url: metadata.source_url,
      model: provider.model,
      tags: %{
        "items" => ["monitoring", "brief", "consultation"],
        "monitoring" => %{
          "source_document_ids" => Enum.map(documents, & &1.id),
          "provider" => provider.name,
          "model" => provider.model
        }
      },
      generated_at: generated_at
    })
  end

  defp monitoring_report_filename(generated_at) do
    stamp = generated_at |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9TZ]/, "")
    "monitoring-brief-#{stamp}.md"
  end

  defp encode_config(config) when is_map(config) do
    case Jason.encode(config) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> "{}"
    end
  end

  defp broadcast_change({:ok, integration} = result, event) do
    Phoenix.PubSub.broadcast(
      BusterClaw.PubSub,
      @topic,
      {:integration_changed, event, integration}
    )

    result
  end

  defp broadcast_change(result, _event), do: result

  defp broadcast_run({:ok, run}) do
    run = Repo.preload(run, [:integration, :document], force: true)
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:integration_run, run})
    {:ok, run}
  end

  defp broadcast_run(result), do: result

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)

  def bounded_error(text) do
    text = to_string(text)

    if String.length(text) > @max_error,
      do: String.slice(text, 0, @max_error) <> "\n[truncated]",
      else: text
  end
end
