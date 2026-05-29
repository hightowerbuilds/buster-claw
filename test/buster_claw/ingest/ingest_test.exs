defmodule BusterClaw.IngestTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Ingest, Library, Sources, Workflow}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

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

  test "browser sources ingest through the browser sidecar boundary" do
    previous_url = Application.get_env(:buster_claw, :browser_sidecar_url)
    previous_options = Application.get_env(:buster_claw, :browser_sidecar_req_options)

    Application.put_env(:buster_claw, :browser_sidecar_url, "http://sidecar.test")

    Application.put_env(:buster_claw, :browser_sidecar_req_options,
      plug: {Req.Test, BusterClaw.BrowserSidecarHTTP}
    )

    on_exit(fn ->
      restore_env(:browser_sidecar_url, previous_url)
      restore_env(:browser_sidecar_req_options, previous_options)
    end)

    Req.Test.stub(BusterClaw.BrowserSidecarHTTP, fn conn ->
      Req.Test.json(conn, %{
        url: "https://example.com/app",
        title: "Rendered App",
        html: "<html><body><h1>Rendered dashboard</h1></body></html>"
      })
    end)

    {:ok, source} =
      Sources.create_source(%{
        url: "https://example.com/app",
        type: "browser",
        tags: %{"items" => ["browser"]},
        browser_engine: "chromium"
      })

    assert {:ok, 1, [{:ok, document}]} = Ingest.ingest_source(source)
    assert document.name == "Rendered App"
    assert document.source_url == "https://example.com/app"

    {:ok, body} = Library.read_raw_document(document)
    assert body =~ "Rendered dashboard"
  end

  defp restore_env(key, nil), do: Application.delete_env(:buster_claw, key)
  defp restore_env(key, value), do: Application.put_env(:buster_claw, key, value)
end
