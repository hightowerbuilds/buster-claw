defmodule BusterClaw.Migration do
  @moduledoc """
  Idempotent importer for legacy Buster Claw library/config files.

  The importer indexes the files in place. It does not copy markdown artifacts into
  the configured library root, so callers can decide when filesystem migration
  should happen.
  """

  alias BusterClaw.Calendar
  alias BusterClaw.Calendar.Event
  alias BusterClaw.Library
  alias BusterClaw.Library.{Artifact, Document, Report}
  alias BusterClaw.Memory
  alias BusterClaw.Memory.Memory, as: MemoryRecord
  alias BusterClaw.Providers
  alias BusterClaw.Providers.Provider
  alias BusterClaw.Repo
  alias BusterClaw.Sources
  alias BusterClaw.Sources.Source

  @source_types ~w(article documentation rss youtube_transcript browser)
  @provider_types ~w(ollama openrouter openai anthropic custom)

  def import_all(opts \\ []) do
    root = Keyword.get(opts, :legacy_root, default_legacy_root())
    library_root = Keyword.get(opts, :library_root, Path.join(root, "Library"))

    %{
      memories: import_memory(Path.join(library_root, "Memory.md")),
      calendar_events: import_calendar(Path.join(library_root, "calendar.json")),
      sources: import_sources(Path.join(root, "sources.json")),
      providers: import_providers(Path.join(root, "providers.json")),
      raw_documents: index_raw_markdown(library_root),
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
      source_file = Map.get(fields, "source_file") || Map.get(fields, "source")
      source_url = Map.get(fields, "url") || Map.get(fields, "source_url")

      attrs = %{
        filename: Path.basename(path),
        artifact_path: relative_path,
        source_file: source_file,
        source_url: source_url,
        model: Map.get(fields, "model"),
        tags: %{"items" => List.wrap(Map.get(fields, "tags", []))},
        generated_at: file_datetime(path)
      }

      case Repo.get_by(Report, artifact_path: relative_path) do
        nil -> Library.create_report(attrs) |> tag_result(:created)
        %Report{} = report -> Library.update_report(report, attrs) |> tag_result(:updated)
      end
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
      browser_engine: Map.get(item, "browser_engine"),
      cookies: Map.get(item, "cookies") || %{},
      enabled: Map.get(item, "enabled", true)
    }
  end

  defp normalize_source(_item), do: nil

  defp normalize_provider(%{} = item) do
    name = Map.get(item, "name") || Map.get(item, "id")
    model = Map.get(item, "model") || Map.get(item, "default_model")

    if present?(name) do
      type = item |> Map.get("type", "custom") |> normalize_type(@provider_types, "custom")

      %{
        name: to_string(name),
        type: type,
        base_url: Map.get(item, "base_url") || Map.get(item, "url"),
        api_key: Map.get(item, "api_key"),
        model: to_string(model || "unknown"),
        active: Map.get(item, "active", false),
        priority: Map.get(item, "priority", 100)
      }
    end
  end

  defp normalize_provider(_item), do: nil

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
        _ -> nil
      end
    end)
  end

  defp json_items(_decoded, _keys), do: []

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

  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_value), do: nil

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

  defp default_legacy_root do
    Path.expand("../..", File.cwd!())
  end

  defp present?(value), do: value not in [nil, ""]
end
