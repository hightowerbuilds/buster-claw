defmodule BusterClaw.IngestTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Ingest, Sources, Workflow}

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
