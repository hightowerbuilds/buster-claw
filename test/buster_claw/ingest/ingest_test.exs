defmodule BusterClaw.IngestTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Ingest, Library, Sources, Workflow}

  test "ingested documents keep their source id" do
    {:ok, source} =
      Sources.create_source(%{
        url: "https://example.com/feed.xml",
        type: "rss",
        tags: %{"items" => ["rss"]}
      })

    fetcher = fn %{url: "https://example.com/feed.xml", type: "rss", tags: ["rss"]} ->
      {:ok,
       [
         %{
           url: "https://example.com/story",
           title: "Linked Story",
           content: "# Linked Story\n\nBody.",
           tags: ["rss"]
         }
       ]}
    end

    assert {:ok, 1, [{:ok, document}]} = Ingest.ingest_source(source, fetcher)
    assert document.source_id == source.id
    assert Library.get_document!(document.id).source_id == source.id
  end

  test "failed ingestion persists a runtime event" do
    {:ok, source} =
      Sources.create_source(%{
        url: "http://127.0.0.1:1/not-running",
        type: "article"
      })

    assert {:error, _reason} = Ingest.ingest_source(source)

    [event] = Workflow.list_runtime_events()
    assert event.kind == "ingest.failed"
    assert event.metadata["url"] == source.url
  end
end
