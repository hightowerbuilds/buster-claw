defmodule BusterClawWeb.IntegrationWebhookControllerTest do
  use BusterClawWeb.ConnCase

  alias BusterClaw.Integrations
  alias BusterClaw.Library

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-integration-webhook-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, previous)
      File.rm_rf(root)
    end)

    :ok
  end

  test "POST /integrations/:name/webhook accepts signed GitHub payloads", %{conn: conn} do
    {:ok, _integration} =
      Integrations.create_integration(%{
        name: "github-main",
        service_type: "github",
        webhook_secret: "webhook-secret",
        config_text: ~s({"owner":"acme","repo":"checkout"})
      })

    body =
      Jason.encode!(%{
        "action" => "opened",
        "pull_request" => %{
          "title" => "Improve checkout",
          "html_url" => "https://github.com/acme/checkout/pull/12"
        },
        "repository" => %{
          "full_name" => "acme/checkout",
          "html_url" => "https://github.com/acme/checkout"
        },
        "sender" => %{"login" => "octocat"}
      })

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", "sha256=#{hmac("webhook-secret", body)}")
      |> post(~p"/integrations/github-main/webhook", body)

    response = json_response(conn, 202)
    assert response["status"] == "accepted"
    assert response["records_fetched"] == 1
    assert response["document_id"]

    assert [document] = Library.list_documents()
    assert document.name == "GitHub Webhook Snapshot: pull_request.opened"
  end

  test "POST /integrations/:name/webhook accepts signed Sentry payloads", %{conn: conn} do
    {:ok, _integration} =
      Integrations.create_integration(%{
        name: "sentry-main",
        service_type: "sentry",
        webhook_secret: "webhook-secret",
        config_text: ~s({"org":"acme","project":"checkout"})
      })

    body =
      Jason.encode!(%{
        "action" => "issue.created",
        "data" => %{
          "issue" => %{
            "title" => "New production error",
            "level" => "error",
            "permalink" => "https://sentry.example.com/issues/1"
          }
        }
      })

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("sentry-hook-signature", hmac("webhook-secret", body))
      |> post(~p"/integrations/sentry-main/webhook", body)

    response = json_response(conn, 202)
    assert response["status"] == "accepted"
    assert response["records_fetched"] == 1

    assert [document] = Library.list_documents()
    assert document.name == "Sentry Webhook Snapshot: issue.created"
  end

  test "POST /integrations/:name/webhook rejects invalid signatures", %{conn: conn} do
    {:ok, _integration} =
      Integrations.create_integration(%{
        name: "github-main",
        service_type: "github",
        webhook_secret: "webhook-secret",
        config_text: ~s({"owner":"acme","repo":"checkout"})
      })

    body = Jason.encode!(%{"action" => "opened", "issue" => %{"title" => "Bug"}})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", "sha256=#{hmac("wrong-secret", body)}")
      |> post(~p"/integrations/github-main/webhook", body)

    assert json_response(conn, 401)["error"] =~ "unauthorized"
    assert [] = Library.list_documents()
  end

  test "POST /integrations/:name/webhook handles missing and disabled integrations", %{conn: conn} do
    body = Jason.encode!(%{"action" => "opened"})

    missing_conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/integrations/missing/webhook", body)

    assert json_response(missing_conn, 404)["error"] == "integration not found"

    {:ok, _integration} =
      Integrations.create_integration(%{
        name: "disabled-github",
        service_type: "github",
        enabled: false,
        config_text: ~s({"owner":"acme","repo":"checkout"})
      })

    disabled_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/integrations/disabled-github/webhook", body)

    assert json_response(disabled_conn, 410)["error"] == "integration disabled"
  end

  defp hmac(secret, body) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end
end
