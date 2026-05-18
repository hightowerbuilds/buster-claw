defmodule BusterClaw.Integrations.UmamiTest do
  use BusterClaw.DataCase

  alias BusterClaw.Integrations
  alias BusterClaw.Library

  setup do
    Req.Test.verify_on_exit!()

    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-umami-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, previous)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "polls Umami and saves a Library snapshot document" do
    Req.Test.stub(BusterClaw.IntegrationHTTP, fn conn ->
      assert List.keyfind(conn.req_headers, "authorization", 0) ==
               {"authorization", "Bearer umami-token"}

      case conn.request_path do
        "/api/websites/site-id/stats" ->
          Req.Test.json(conn, %{
            pageviews: 1200,
            visitors: 420,
            visits: 510,
            bounces: 82,
            totaltime: 19_200
          })

        "/api/websites/site-id/metrics" ->
          conn = Plug.Conn.fetch_query_params(conn)

          rows =
            case conn.query_params["type"] do
              "url" -> [%{x: "/", y: 750}, %{x: "/pricing", y: 230}]
              "referrer" -> [%{x: "github.com", y: 90}]
              "country" -> [%{x: "US", y: 300}]
              "browser" -> [%{x: "Chrome", y: 220}]
              "os" -> [%{x: "macOS", y: 160}]
              "device" -> [%{x: "desktop", y: 380}]
            end

          Req.Test.json(conn, rows)
      end
    end)

    {:ok, integration} =
      Integrations.create_integration(%{
        name: "Marketing Site",
        service_type: "umami",
        base_url: "https://umami.example.com",
        token: "umami-token",
        config_text: ~s({"website_id":"site-id","period":"24h"})
      })

    assert {:ok, run} =
             Integrations.poll_integration(integration,
               req_options: [plug: {Req.Test, BusterClaw.IntegrationHTTP}],
               now: ~U[2026-05-18 12:00:00Z]
             )

    assert run.status == "ok"
    assert run.records_fetched == 1
    assert run.document_id
    assert [document] = Library.list_documents()
    assert document.id == run.document_id
    assert document.name == "Umami Analytics Snapshot: site-id"
    assert document.tags == %{"items" => ["integration", "umami", "analytics", "monitoring"]}

    assert {:ok, body} = Library.read_raw_document(document)
    assert body =~ "# Umami Analytics Snapshot: site-id"
    assert body =~ "- Service: Umami"
    assert body =~ "- Integration: Marketing Site"
    assert body =~ "- Pageviews: 1200"
    assert body =~ "## Top Pages"
    assert body =~ "- /: 750"
    assert body =~ "## Referrers"
    assert body =~ "- github.com: 90"

    integration = Integrations.get_integration!(integration.id)
    assert integration.last_status == "ok"
    assert is_nil(integration.last_error)
  end

  test "returns a run error when required Umami config is missing" do
    {:ok, integration} =
      Integrations.create_integration(%{
        name: "Missing Website",
        service_type: "umami",
        base_url: "https://umami.example.com"
      })

    assert {:error, run} = Integrations.poll_integration(integration)
    assert run.status == "error"
    assert run.error =~ "missing_config"
    assert [] = Library.list_documents()

    integration = Integrations.get_integration!(integration.id)
    assert integration.last_status == "error"
    assert integration.last_error =~ "missing_config"
  end

  test "records an error run when Umami returns an HTTP error" do
    Req.Test.stub(BusterClaw.IntegrationHTTP, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{error: "unauthorized"})
    end)

    {:ok, integration} =
      Integrations.create_integration(%{
        name: "Bad Token",
        service_type: "umami",
        base_url: "https://umami.example.com",
        token: "bad-token",
        config_text: ~s({"website_id":"site-id"})
      })

    assert {:error, run} =
             Integrations.poll_integration(integration,
               req_options: [plug: {Req.Test, BusterClaw.IntegrationHTTP}]
             )

    assert run.status == "error"
    assert run.error =~ "http_error"
    assert [] = Library.list_documents()
  end
end
