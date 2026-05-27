defmodule BusterClaw.Ingest do
  @moduledoc "Coordinates source ingestion into the local Library."

  alias BusterClaw.Ingest.Fetcher
  alias BusterClaw.Library
  alias BusterClaw.Sources.Source
  alias BusterClaw.Workflow

  def ingest_source(%Source{} = source, fetcher \\ &Fetcher.fetch/1)
      when is_function(fetcher, 1) do
    broadcast(:ingest_started, %{source_id: source.id, url: source.url})

    source
    |> source_attrs()
    |> fetcher.()
    |> save_items(source)
    |> tap(&record_source_result(source, &1))
  end

  def ingest_sources(sources) do
    sources
    |> Enum.map(&ingest_source/1)
    |> summarize()
  end

  defp source_attrs(source) do
    %{
      url: source.url,
      type: source.type,
      tags: Map.get(source.tags || %{}, "items", [])
    }
  end

  defp save_items({:ok, items}, %Source{} = source) do
    results =
      Enum.map(items, fn item ->
        Library.save_raw_document(%{
          date: Date.utc_today(),
          source_id: source.id,
          filename: item.title || item.url,
          source_url: item.url,
          name: item.title,
          tags: item.tags,
          content: item.content,
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
      end)

    {:ok, Enum.count(results, &match?({:ok, _}, &1)), results}
  end

  defp save_items({:error, reason}, _source), do: {:error, reason}

  defp summarize(results) do
    saved =
      results
      |> Enum.map(fn
        {:ok, count, _items} -> count
        _ -> 0
      end)
      |> Enum.sum()

    errors =
      Enum.flat_map(results, fn
        {:error, reason} -> [reason]
        {:ok, _count, item_results} -> item_errors(item_results)
      end)

    %{saved: saved, errors: errors}
  end

  defp item_errors(results) do
    Enum.flat_map(results, fn
      {:ok, _document} -> []
      {:error, reason} -> [reason]
    end)
  end

  defp record_source_result(source, {:ok, count, item_results}) do
    errors = item_errors(item_results)
    message = "Ingested #{count} documents from #{source.url}"

    record_event("ingest.finished", message, %{
      source_id: source.id,
      url: source.url,
      saved: count,
      errors: Enum.map(errors, &inspect/1)
    })

    broadcast(:ingest_finished, %{
      source_id: source.id,
      url: source.url,
      saved: count,
      errors: errors
    })

    broadcast(:documents_changed, %{source_id: source.id, saved: count})
  end

  defp record_source_result(source, {:error, reason}) do
    record_event("ingest.failed", "Ingest failed for #{source.url}", %{
      source_id: source.id,
      url: source.url,
      error: inspect(reason)
    })

    broadcast(:ingest_failed, %{source_id: source.id, url: source.url, error: reason})
  end

  defp record_event(kind, message, metadata) do
    Workflow.create_runtime_event(%{
      kind: kind,
      message: message,
      metadata: metadata,
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, "sources", {event, payload})
  end
end
