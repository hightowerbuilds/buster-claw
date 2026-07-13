defmodule BusterClaw.Integrations do
  @moduledoc """
  Service integrations (GitHub / Sentry / Umami) that turn operational data into
  Library documents. Both the poll path and the webhook path converge on the same
  output: a Library markdown snapshot plus an `IntegrationRun` row.

  ## Two things this does NOT do

  **Nothing here is scheduled.** There is no integration poller. `poll_integration/2`
  and `poll_all/1` run only when something calls them — the two buttons in
  `IntegrationsLive`, or the `integration_poll` / `integration_poll_all` agent
  commands. `Integration.polling_interval_minutes` is stored, validated, and shown
  in the settings form, but **no scheduler reads it** (only `Wallets` honours a
  polling interval, on its own feeds). Don't infer a background cadence from that
  field.

  **Integrations never enqueue Dispatch work.** A poll or a verified webhook writes
  documents and broadcasts `{:integration_run, run}` on the `"integrations"` topic;
  the only subscriber is `WalletPoller`, which stamps a record count onto any wallet
  feed bound to the integration. The Dispatch queue is fed by Gmail trusted-senders
  only (`Google.GmailSync`). A GitHub push does not become agent work.
  """

  import Ecto.Query

  alias BusterClaw.Integrations.{GitHub, Integration, IntegrationRun, Sentry, Umami}
  alias BusterClaw.Library
  alias BusterClaw.LocalTime
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
           {:ok, documents, skipped_snapshots} <- save_poll_snapshot_items(integration, items) do
        {:ok, items, documents, skipped_snapshots}
      end

    case result do
      {:ok, items, documents, skipped_snapshots} ->
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
            metadata: poll_metadata(integration, documents, skipped_snapshots)
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

  defp save_poll_snapshot_items(%Integration{} = integration, items) do
    dedupe = dedupe_options(integration)
    candidates = if dedupe.enabled, do: dedupe_candidates(integration, dedupe), else: []

    items
    |> List.wrap()
    |> Enum.reduce_while({:ok, [], [], candidates}, fn item,
                                                       {:ok, documents, skipped, candidates} ->
      case duplicate_snapshot(item, candidates) do
        {:duplicate, document} ->
          skipped_item = skipped_snapshot(item, document)
          {:cont, {:ok, documents, [skipped_item | skipped], candidates}}

        :unique ->
          case Library.save_raw_document(item) do
            {:ok, document} ->
              {:cont, {:ok, [document | documents], skipped, [document | candidates]}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, documents, skipped, _candidates} ->
        {:ok, Enum.reverse(documents), Enum.reverse(skipped)}

      {:error, reason} ->
        {:error, reason}
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

  defp poll_metadata(%Integration{} = integration, documents, skipped_snapshots) do
    dedupe = dedupe_options(integration)

    %{
      "service_type" => integration.service_type,
      "documents" => Enum.map(documents, & &1.artifact_path),
      "dedupe" => %{
        "enabled" => dedupe.enabled,
        "window_days" => dedupe.window_days,
        "saved" => length(documents),
        "skipped" => skipped_snapshots
      }
    }
  end

  defp dedupe_options(%Integration{config: config}) do
    config = config || %{}

    %{
      enabled: enabled_config?(%Integration{config: config}, "dedupe_poll_snapshots"),
      window_days: dedupe_window_days(Map.get(config, "dedupe_window_days", 30))
    }
  end

  defp dedupe_window_days(value) when value in [nil, "", false], do: nil
  defp dedupe_window_days(value) when is_integer(value) and value > 0, do: value

  defp dedupe_window_days(value) when is_binary(value) do
    value = String.trim(value)

    if String.downcase(value) in ["all", "none", "unlimited"] do
      nil
    else
      case Integer.parse(value) do
        {days, ""} when days > 0 -> days
        _other -> 30
      end
    end
  end

  defp dedupe_window_days(_value), do: 30

  defp dedupe_candidates(%Integration{} = integration, dedupe) do
    # Push the date window + service-type tag filter into SQL so we don't load
    # (and reject) the entire documents table on every poll.
    [tag: integration.service_type, since: dedupe_since(dedupe.window_days)]
    |> Library.list_documents()
    |> Enum.filter(&integration_document?/1)
    # Deleted documents have no artifact on disk; the previous file-read compare
    # treated them as non-matches, so exclude them to keep dedupe semantics.
    |> Enum.reject(&(&1.status == "deleted"))
  end

  defp dedupe_since(nil), do: nil
  defp dedupe_since(window_days), do: Date.add(LocalTime.today(), -window_days)

  defp duplicate_snapshot(item, candidates) do
    Enum.find_value(candidates, :unique, fn document ->
      if same_snapshot?(item, document), do: {:duplicate, document}, else: false
    end)
  end

  defp same_snapshot?(item, document) do
    item_name = item_attr(item, :name)
    item_url = item_attr(item, :source_url)

    document.name == item_name and document.source_url == item_url and
      same_snapshot_body?(item, document)
  end

  defp same_snapshot_body?(item, document) do
    # Compare against the stored body hash instead of reading the artifact back
    # off disk. `content_hash` is taken over the trimmed body, so hashing the
    # incoming body the same way reproduces it without a filesystem read.
    Library.body_hash(snapshot_body(item)) == document.content_hash
  end

  defp skipped_snapshot(item, document) do
    %{
      "name" => item_attr(item, :name),
      "source_url" => item_attr(item, :source_url),
      "duplicate_of" => document.artifact_path
    }
  end

  defp snapshot_body(item), do: item_attr(item, :content) || item_attr(item, :body) || ""

  defp item_attr(item, key) when is_map(item),
    do: Map.get(item, key) || Map.get(item, Atom.to_string(key))

  defp item_attr(_item, _key), do: nil

  defp document_tags(document), do: get_in(document.tags || %{}, ["items"]) || []

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

  defp trigger(opts), do: opts |> Keyword.get(:trigger, "manual") |> to_string()

  defp enabled_config?(%Integration{config: config}, key) when is_map(config) do
    case Map.get(config, key) do
      true -> true
      1 -> true
      value when is_binary(value) -> String.downcase(value) in ["1", "true", "yes", "on"]
      _value -> false
    end
  end

  defp enabled_config?(_integration, _key), do: false

  defp integration_document?(document) do
    "integration" in document_tags(document)
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
