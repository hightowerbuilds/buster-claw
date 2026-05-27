defmodule BusterClaw.Migration do
  @moduledoc """
  Idempotent importer for legacy Buster Claw library/config files.

  The importer indexes the files in place. It does not copy markdown artifacts into
  the configured library root, so callers can decide when filesystem migration
  should happen.
  """

  alias BusterClaw.Automation
  alias BusterClaw.Automation.{DeliveryDestination, Hook, MCPServer, SchedulerJob, Webhook}
  alias BusterClaw.Calendar
  alias BusterClaw.Calendar.Event
  alias BusterClaw.Library
  alias BusterClaw.Library.{Artifact, Document, Report}
  alias BusterClaw.Memory
  alias BusterClaw.Memory.Memory, as: MemoryRecord
  alias BusterClaw.Providers
  alias BusterClaw.Providers.Provider
  alias BusterClaw.Repo
  alias BusterClaw.Scheduler.Cron
  alias BusterClaw.Sources
  alias BusterClaw.Sources.Source

  @source_types ~w(article documentation rss youtube_transcript browser)
  @provider_types ~w(ollama openrouter openai anthropic custom)
  @delivery_types ~w(slack discord telegram email)
  @hook_events ~w(pre_ingest post_ingest pre_analysis post_analysis pre_report post_report on_error)
  @hook_types ~w(shell webhook)
  @webhook_actions ~w(ingest analyze full command)
  @scheduler_types ~w(ingest analyze full digest custom integrations_poll monitoring_brief)

  def import_all(opts \\ []) do
    root = Keyword.get(opts, :legacy_root, default_legacy_root())
    library_root = Keyword.get(opts, :library_root, Path.join(root, "Library"))

    %{
      memories: import_memory(Path.join(library_root, "Memory.md")),
      calendar_events: import_calendar(Path.join(library_root, "calendar.json")),
      sources: import_sources(Path.join(root, "sources.json")),
      providers: import_providers(Path.join(root, "providers.json")),
      mcp_servers: import_mcp(Path.join(root, "mcp.json")),
      delivery_destinations: import_delivery(Path.join(library_root, "delivery.json")),
      hooks: import_hooks(Path.join(library_root, "hooks.json")),
      webhooks: import_webhooks(Path.join(library_root, "webhooks.json")),
      scheduler_jobs: import_scheduler(Path.join(library_root, "scheduler.json")),
      raw_documents: index_raw_markdown(library_root),
      report_manifest:
        import_report_manifest(
          Path.join([library_root, "reports", "manifest.json"]),
          library_root
        ),
      reports: index_reports(library_root)
    }
  end

  def import_memory(path) do
    case File.read(path) do
      {:ok, content} ->
        created_at = file_datetime(path)

        content
        |> parse_memory_markdown()
        |> Enum.map(&upsert_memory(%{created_at: created_at, text: &1}))
        |> summarize_results()

      {:error, :enoent} ->
        %{created: 0, updated: 0, skipped: 1, errors: []}

      {:error, reason} ->
        %{created: 0, updated: 0, skipped: 0, errors: [{path, reason}]}
    end
  end

  def import_calendar(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      decoded
      |> json_items(["events", "calendar"])
      |> Enum.map(&normalize_event/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&upsert_event/1)
      |> summarize_results()
    else
      {:error, :enoent} -> %{created: 0, updated: 0, skipped: 1, errors: []}
      {:error, reason} -> %{created: 0, updated: 0, skipped: 0, errors: [{path, reason}]}
    end
  end

  def import_sources(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      decoded
      |> json_items(["sources"])
      |> Enum.map(&normalize_source/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&upsert_source/1)
      |> summarize_results()
    else
      {:error, :enoent} -> %{created: 0, updated: 0, skipped: 1, errors: []}
      {:error, reason} -> %{created: 0, updated: 0, skipped: 0, errors: [{path, reason}]}
    end
  end

  def import_providers(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      decoded
      |> json_items(["providers"])
      |> Enum.map(&normalize_provider/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&upsert_provider/1)
      |> summarize_results()
    else
      {:error, :enoent} -> %{created: 0, updated: 0, skipped: 1, errors: []}
      {:error, reason} -> %{created: 0, updated: 0, skipped: 0, errors: [{path, reason}]}
    end
  end

  def import_mcp(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      decoded
      |> json_items(["servers", "mcpServers", "mcp_servers"])
      |> Enum.map(&normalize_mcp_server/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&upsert_mcp_server/1)
      |> summarize_results()
    else
      {:error, :enoent} -> %{created: 0, updated: 0, skipped: 1, errors: []}
      {:error, reason} -> %{created: 0, updated: 0, skipped: 0, errors: [{path, reason}]}
    end
  end

  def import_delivery(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      decoded
      |> json_items(["destinations", "delivery_destinations", "delivery"])
      |> Enum.map(&normalize_delivery_destination/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&upsert_delivery_destination/1)
      |> summarize_results()
    else
      {:error, :enoent} -> %{created: 0, updated: 0, skipped: 1, errors: []}
      {:error, reason} -> %{created: 0, updated: 0, skipped: 0, errors: [{path, reason}]}
    end
  end

  def import_hooks(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      decoded
      |> json_items(["hooks"])
      |> Enum.map(&normalize_hook/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&upsert_hook/1)
      |> summarize_results()
    else
      {:error, :enoent} -> %{created: 0, updated: 0, skipped: 1, errors: []}
      {:error, reason} -> %{created: 0, updated: 0, skipped: 0, errors: [{path, reason}]}
    end
  end

  def import_webhooks(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      decoded
      |> json_items(["webhooks", "hooks"])
      |> Enum.map(&normalize_webhook/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&upsert_webhook/1)
      |> summarize_results()
    else
      {:error, :enoent} -> %{created: 0, updated: 0, skipped: 1, errors: []}
      {:error, reason} -> %{created: 0, updated: 0, skipped: 0, errors: [{path, reason}]}
    end
  end

  def import_scheduler(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      decoded
      |> json_items(["jobs", "scheduler"])
      |> Enum.map(&normalize_scheduler_job/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&upsert_scheduler_job/1)
      |> summarize_results()
    else
      {:error, :enoent} -> %{created: 0, updated: 0, skipped: 1, errors: []}
      {:error, reason} -> %{created: 0, updated: 0, skipped: 0, errors: [{path, reason}]}
    end
  end

  def import_report_manifest(path, library_root) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content) do
      decoded
      |> json_items(["reports", "items", "entries", "manifest"])
      |> Enum.map(&normalize_report_manifest_entry(&1, library_root))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&upsert_report/1)
      |> summarize_results()
    else
      {:error, :enoent} -> %{created: 0, updated: 0, skipped: 1, errors: []}
      {:error, reason} -> %{created: 0, updated: 0, skipped: 0, errors: [{path, reason}]}
    end
  end

  def index_raw_markdown(library_root) do
    library_root
    |> Path.join("raw/**/*.md")
    |> Path.wildcard()
    |> Enum.map(&index_raw_file(&1, library_root))
    |> summarize_results()
  end

  def index_reports(library_root) do
    library_root
    |> Path.join("reports/**/*.md")
    |> Path.wildcard()
    |> Enum.map(&index_report_file(&1, library_root))
    |> summarize_results()
  end

  defp upsert_memory(attrs) do
    case Repo.get_by(MemoryRecord, text: attrs.text, created_at: attrs.created_at) do
      nil -> Memory.create_memory(attrs) |> tag_result(:created)
      %MemoryRecord{} = memory -> Memory.update_memory(memory, attrs) |> tag_result(:updated)
    end
  end

  defp upsert_event(attrs) do
    case Repo.get_by(Event, event_id: attrs.event_id) do
      nil -> Calendar.create_event(attrs) |> tag_result(:created)
      %Event{} = event -> Calendar.update_event(event, attrs) |> tag_result(:updated)
    end
  end

  defp upsert_source(attrs) do
    case Repo.get_by(Source, url: attrs.url) do
      nil -> Sources.create_source(attrs) |> tag_result(:created)
      %Source{} = source -> Sources.update_source(source, attrs) |> tag_result(:updated)
    end
  end

  defp upsert_provider(attrs) do
    case Repo.get_by(Provider, name: attrs.name) do
      nil -> Providers.create_provider(attrs) |> tag_result(:created)
      %Provider{} = provider -> Providers.update_provider(provider, attrs) |> tag_result(:updated)
    end
  end

  defp upsert_mcp_server(attrs) do
    case Repo.get_by(MCPServer, name: attrs.name) do
      nil -> Automation.create_mcp_server(attrs) |> tag_result(:created)
      %MCPServer{} = server -> Automation.update_mcp_server(server, attrs) |> tag_result(:updated)
    end
  end

  defp upsert_delivery_destination(attrs) do
    case Repo.get_by(DeliveryDestination, name: attrs.name) do
      nil ->
        Automation.create_delivery_destination(attrs) |> tag_result(:created)

      %DeliveryDestination{} = destination ->
        Automation.update_delivery_destination(destination, attrs) |> tag_result(:updated)
    end
  end

  defp upsert_hook(attrs) do
    case Repo.get_by(Hook, name: attrs.name, event: attrs.event) do
      nil -> Automation.create_hook(attrs) |> tag_result(:created)
      %Hook{} = hook -> Automation.update_hook(hook, attrs) |> tag_result(:updated)
    end
  end

  defp upsert_webhook(attrs) do
    case Repo.get_by(Webhook, name: attrs.name) do
      nil -> Automation.create_webhook(attrs) |> tag_result(:created)
      %Webhook{} = webhook -> Automation.update_webhook(webhook, attrs) |> tag_result(:updated)
    end
  end

  defp upsert_scheduler_job(attrs) do
    case Repo.get_by(SchedulerJob, job_id: attrs.job_id) do
      nil ->
        Automation.create_scheduler_job(attrs) |> tag_result(:created)

      %SchedulerJob{} = job ->
        Automation.update_scheduler_job(job, attrs) |> tag_result(:updated)
    end
  end

  defp upsert_report(attrs) do
    case Repo.get_by(Report, artifact_path: attrs.artifact_path) do
      nil -> Library.create_report(attrs) |> tag_result(:created)
      %Report{} = report -> Library.update_report(report, attrs) |> tag_result(:updated)
    end
  end

  defp index_raw_file(path, library_root) do
    with {:ok, parsed} <- Artifact.parse_markdown_file(path) do
      fields = parsed.fields
      relative_path = relative_to(path, library_root)

      attrs = %{
        filename: Path.basename(path),
        artifact_path: relative_path,
        date: date_from_path(path),
        source_url: Map.get(fields, "url"),
        name: Map.get(fields, "name"),
        tags: %{"items" => List.wrap(Map.get(fields, "tags", []))},
        content_hash: parsed.content_hash,
        excerpt: parsed.excerpt,
        fetched_at: file_datetime(path)
      }

      case Repo.get_by(Document, artifact_path: relative_path) do
        nil -> Library.create_document(attrs) |> tag_result(:created)
        %Document{} = document -> Library.update_document(document, attrs) |> tag_result(:updated)
      end
    end
  end

  defp index_report_file(path, library_root) do
    with {:ok, parsed} <- Artifact.parse_markdown_file(path) do
      fields = parsed.fields
      relative_path = relative_to(path, library_root)
      existing_report = Repo.get_by(Report, artifact_path: relative_path)
      source_file = Map.get(fields, "source_file") || Map.get(fields, "source")
      source_url = Map.get(fields, "url") || Map.get(fields, "source_url")
      tags = %{"items" => List.wrap(Map.get(fields, "tags", []))}

      attrs = %{
        filename: Path.basename(path),
        artifact_path: relative_path,
        source_file: source_file || existing_value(existing_report, :source_file),
        source_url: source_url || existing_value(existing_report, :source_url),
        model: Map.get(fields, "model") || existing_value(existing_report, :model),
        tags: keep_existing_tags(tags, existing_report),
        generated_at:
          parse_datetime(first_present(fields, ["generated_at", "generatedAt", "date"])) ||
            existing_value(existing_report, :generated_at) ||
            file_datetime(path)
      }

      upsert_report(attrs)
    end
  end

  defp normalize_event(%{} = item) do
    date = parse_date(Map.get(item, "date") || Map.get(item, "day"))
    title = Map.get(item, "title") || Map.get(item, "name") || Map.get(item, "summary")

    if date && present?(title) do
      event_id =
        Map.get(item, "event_id") || Map.get(item, "id") || stable_id("event", date, title)

      %{
        event_id: to_string(event_id),
        date: date,
        title: to_string(title),
        notes: Map.get(item, "notes") || Map.get(item, "description") || Map.get(item, "body")
      }
    end
  end

  defp normalize_event(_item), do: nil

  defp normalize_source(%{"url" => url} = item) when is_binary(url) do
    type = item |> Map.get("type", "article") |> normalize_type(@source_types, "article")

    %{
      url: url,
      type: type,
      name: Map.get(item, "name"),
      tags: %{"items" => List.wrap(Map.get(item, "tags", []))},
      browser_engine: first_present(item, ["browser_engine", "browserEngine"]),
      cookies: Map.get(item, "cookies") || %{},
      enabled: Map.get(item, "enabled", true)
    }
  end

  defp normalize_source(_item), do: nil

  defp normalize_provider(%{} = item) do
    name = first_present(item, ["name", "id"])
    model = first_present(item, ["model", "default_model", "defaultModel"])

    if present?(name) do
      type = item |> Map.get("type", "custom") |> normalize_type(@provider_types, "custom")

      %{
        name: to_string(name),
        type: type,
        base_url: first_present(item, ["base_url", "baseUrl", "url"]),
        api_key: first_present(item, ["api_key", "apiKey"]),
        model: to_string(model || "unknown"),
        active: Map.get(item, "active", false),
        priority: Map.get(item, "priority", 100)
      }
    end
  end

  defp normalize_provider(_item), do: nil

  defp normalize_mcp_server(%{} = item) do
    name = first_present(item, ["name", "id"])
    command = first_present(item, ["command", "cmd", "executable"])

    if present?(name) && present?(command) do
      %{
        name: to_string(name),
        command: to_string(command),
        args: normalize_args(first_present(item, ["args", "arguments"])),
        env: normalize_env(first_present(item, ["env", "environment"])),
        enabled: normalize_boolean(first_present(item, ["enabled", "active"]), true),
        last_status: first_present(item, ["last_status", "lastStatus", "status"]),
        last_error: first_present(item, ["last_error", "lastError", "error"]),
        last_connected_at:
          parse_datetime(first_present(item, ["last_connected_at", "lastConnectedAt"]))
      }
    end
  end

  defp normalize_mcp_server(_item), do: nil

  defp normalize_delivery_destination(%{} = item) do
    name = first_present(item, ["name", "id"])

    if present?(name) do
      type =
        item
        |> first_present(["type", "kind"])
        |> normalize_type(@delivery_types, "slack")

      %{
        name: to_string(name),
        type: type,
        url: first_present(item, ["url", "webhook_url", "webhookUrl"]),
        token: first_present(item, ["token", "api_key", "apiKey"]),
        chat_id: first_present(item, ["chat_id", "chatId", "channel"]),
        enabled: normalize_boolean(first_present(item, ["enabled", "active"]), true)
      }
    end
  end

  defp normalize_delivery_destination(_item), do: nil

  defp normalize_hook(%{} = item) do
    name = first_present(item, ["name", "id"])
    event = item |> first_present(["event", "trigger"]) |> normalize_allowed(@hook_events)
    target = first_present(item, ["target", "command", "cmd", "url"])

    type =
      item
      |> first_present(["type", "kind"])
      |> inferred_hook_type(target)

    if present?(name) && present?(event) && present?(type) && present?(target) do
      %{
        name: to_string(name),
        event: event,
        type: type,
        target: to_string(target),
        async: normalize_boolean(first_present(item, ["async", "run_async", "runAsync"]), true),
        enabled: normalize_boolean(first_present(item, ["enabled", "active"]), true)
      }
    end
  end

  defp normalize_hook(_item), do: nil

  defp normalize_webhook(%{} = item) do
    name = first_present(item, ["name", "id"])
    custom_cmd = first_present(item, ["custom_cmd", "customCmd", "command", "cmd"])

    if present?(name) do
      default_action = if present?(custom_cmd), do: "command", else: "full"

      %{
        name: to_string(name),
        secret: first_present(item, ["secret", "token"]),
        action:
          item
          |> first_present(["action", "type"])
          |> normalize_type(@webhook_actions, default_action),
        custom_cmd: custom_cmd,
        deliver_to: first_present(item, ["deliver_to", "deliverTo"]),
        enabled: normalize_boolean(first_present(item, ["enabled", "active"]), true)
      }
    end
  end

  defp normalize_webhook(_item), do: nil

  defp normalize_scheduler_job(%{} = item) do
    job_id = first_present(item, ["job_id", "jobId", "id", "name"])

    if present?(job_id) do
      custom_cmd = first_present(item, ["custom_cmd", "customCmd", "command", "cmd"])
      default_type = if present?(custom_cmd), do: "custom", else: "ingest"
      cron_value = first_present(item, ["cron", "schedule", "expression"])
      {cron, enabled, last_error, next_run_at} = normalize_cron(cron_value, item)
      legacy_next_run_at = parse_datetime(first_present(item, ["next_run_at", "nextRunAt"]))

      %{
        job_id: to_string(job_id),
        type:
          item
          |> first_present(["type", "action", "kind"])
          |> normalize_type(@scheduler_types, default_type),
        cron: cron,
        enabled: enabled,
        custom_cmd: custom_cmd,
        deliver_to: first_present(item, ["deliver_to", "deliverTo"]),
        last_run_at: parse_datetime(first_present(item, ["last_run_at", "lastRunAt"])),
        next_run_at: if(enabled, do: legacy_next_run_at || next_run_at),
        last_error: last_error || first_present(item, ["last_error", "lastError", "error"])
      }
    end
  end

  defp normalize_scheduler_job(_item), do: nil

  defp normalize_report_manifest_entry(%{} = item, library_root) do
    path =
      first_present(item, [
        "artifact_path",
        "artifactPath",
        "path",
        "file",
        "report_file",
        "reportFile"
      ])

    relative_path = normalize_report_path(path, library_root)

    if present?(relative_path) && File.exists?(Path.join(library_root, relative_path)) do
      %{
        filename: Path.basename(relative_path),
        artifact_path: relative_path,
        source_file: first_present(item, ["source_file", "sourceFile", "source"]),
        source_url: first_present(item, ["source_url", "sourceUrl", "url"]),
        model: first_present(item, ["model", "provider_model", "providerModel"]),
        tags: %{"items" => List.wrap(first_present(item, ["tags"]) || [])},
        generated_at:
          parse_datetime(
            first_present(item, ["generated_at", "generatedAt", "created_at", "createdAt"])
          ) ||
            file_datetime(Path.join(library_root, relative_path))
      }
    end
  end

  defp normalize_report_manifest_entry(_item, _library_root), do: nil

  defp parse_memory_markdown(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(&String.replace(&1, ~r/^[-*]\s+/, ""))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp json_items(items, _keys) when is_list(items), do: items

  defp json_items(%{} = map, keys) do
    Enum.find_value(keys, [], fn key ->
      case Map.get(map, key) do
        items when is_list(items) -> items
        %{} = items -> named_map_items(items)
        _ -> nil
      end
    end)
  end

  defp json_items(_decoded, _keys), do: []

  defp named_map_items(items) do
    Enum.map(items, fn {name, attrs} ->
      attrs
      |> ensure_map()
      |> Map.put_new("name", name)
      |> Map.put_new("id", name)
      |> Map.put_new("path", name)
    end)
  end

  defp summarize_results(results) do
    Enum.reduce(results, %{created: 0, updated: 0, skipped: 0, errors: []}, fn
      {:created, _record}, acc -> Map.update!(acc, :created, &(&1 + 1))
      {:updated, _record}, acc -> Map.update!(acc, :updated, &(&1 + 1))
      {:skipped, _reason}, acc -> Map.update!(acc, :skipped, &(&1 + 1))
      {:error, reason}, acc -> Map.update!(acc, :errors, &[reason | &1])
    end)
    |> Map.update!(:errors, &Enum.reverse/1)
  end

  defp tag_result({:ok, record}, tag), do: {tag, record}
  defp tag_result({:error, reason}, _tag), do: {:error, reason}

  defp normalize_type(value, allowed, fallback) do
    value = value |> to_string() |> String.downcase()
    if value in allowed, do: value, else: fallback
  end

  defp normalize_allowed(value, _allowed) when value in [nil, ""], do: nil

  defp normalize_allowed(value, allowed) do
    normalized = value |> to_string() |> String.downcase()
    if normalized in allowed, do: normalized
  end

  defp inferred_hook_type(value, target) do
    case normalize_allowed(value, @hook_types) do
      nil ->
        if target |> to_string() |> String.starts_with?(["http://", "https://"]) do
          "webhook"
        else
          "shell"
        end

      type ->
        type
    end
  end

  defp normalize_args(nil), do: %{}
  defp normalize_args(%{} = value), do: value
  defp normalize_args(value) when is_list(value), do: %{"items" => value}

  defp normalize_args(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = decoded} -> decoded
      {:ok, decoded} when is_list(decoded) -> %{"items" => decoded}
      _ -> %{"items" => [value]}
    end
  end

  defp normalize_args(value), do: %{"items" => List.wrap(value)}

  defp normalize_env(nil), do: %{}
  defp normalize_env(%{} = value), do: value

  defp normalize_env(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = decoded} -> decoded
      _ -> %{}
    end
  end

  defp normalize_env(_value), do: %{}

  defp normalize_boolean(value, default) when value in [nil, ""], do: default
  defp normalize_boolean(value, _default) when is_boolean(value), do: value
  defp normalize_boolean(value, _default) when is_integer(value), do: value != 0

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

  defp normalize_cron(value, item) do
    enabled = normalize_boolean(first_present(item, ["enabled", "active"]), true)
    cron = if present?(value), do: to_string(value), else: "@daily"

    cond do
      !present?(value) ->
        {"@daily", false, "Missing legacy cron expression; imported disabled.", nil}

      enabled ->
        case Cron.next_run(cron) do
          {:ok, next_run_at} -> {cron, true, nil, next_run_at}
          {:error, _reason} -> {cron, false, "Invalid legacy cron expression: #{cron}", nil}
        end

      true ->
        if Cron.valid?(cron) do
          {cron, false, nil, nil}
        else
          {cron, false, "Invalid legacy cron expression: #{cron}", nil}
        end
    end
  end

  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp parse_datetime(%DateTime{} = datetime), do: DateTime.truncate(datetime, :second)

  defp parse_datetime(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.truncate(:second)
  end

  defp parse_datetime(value) when is_binary(value) do
    with {:error, _reason} <- DateTime.from_iso8601(value),
         {:ok, datetime} <- NaiveDateTime.from_iso8601(value) do
      parse_datetime(datetime)
    else
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp date_from_path(path) do
    path
    |> Path.dirname()
    |> Path.basename()
    |> Date.from_iso8601()
    |> case do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp file_datetime(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, datetime} <- DateTime.from_unix(stat.mtime) do
      DateTime.truncate(datetime, :second)
    else
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp stable_id(prefix, date, title) do
    key = "#{prefix}:#{date}:#{title}"
    hash = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    "#{prefix}-#{hash}"
  end

  defp relative_to(path, library_root) do
    path
    |> Path.expand()
    |> Path.relative_to(Path.expand(library_root))
  end

  defp normalize_report_path(path, _library_root) when path in [nil, ""], do: nil

  defp normalize_report_path(path, library_root) do
    path = to_string(path)

    relative_path =
      cond do
        Path.type(path) == :absolute ->
          relative_to(path, library_root)

        String.starts_with?(path, "Library/") ->
          String.replace_prefix(path, "Library/", "")

        String.starts_with?(path, "reports/") ->
          path

        Path.extname(path) == ".md" && Path.dirname(path) != "." ->
          path

        Path.extname(path) == ".md" ->
          Path.join("reports", path)

        true ->
          nil
      end

    if safe_relative_path?(relative_path, library_root), do: relative_path
  end

  defp safe_relative_path?(path, _library_root) when path in [nil, ""], do: false

  defp safe_relative_path?(path, library_root) do
    library_root = Path.expand(library_root)
    expanded_path = Path.expand(Path.join(library_root, path))

    Path.type(path) == :relative &&
      !String.starts_with?(path, "..") &&
      (expanded_path == library_root || String.starts_with?(expanded_path, library_root <> "/"))
  end

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      value = Map.get(map, key)
      if present?(value), do: value
    end)
  end

  defp keep_existing_tags(%{"items" => []}, %Report{tags: tags}) when is_map(tags), do: tags
  defp keep_existing_tags(tags, _existing_report), do: tags

  defp existing_value(nil, _field), do: nil
  defp existing_value(struct, field), do: Map.get(struct, field)

  defp ensure_map(%{} = value), do: value
  defp ensure_map(_value), do: %{}

  defp default_legacy_root do
    Path.expand("../..", File.cwd!())
  end

  defp present?(value), do: value not in [nil, ""]
end
