defmodule BusterClaw.Integrations.SentryTest do
  use BusterClaw.DataCase

  alias BusterClaw.Integrations
  alias BusterClaw.Library

  setup do
    Req.Test.verify_on_exit!()

    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-sentry-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, previous)
      File.rm_rf(root)
    end)

    :ok
  end

  test "polls Sentry issues and saves a Library snapshot document" do
    Req.Test.stub(BusterClaw.IntegrationHTTP, fn conn ->
      assert List.keyfind(conn.req_headers, "authorization", 0) ==
               {"authorization", "Bearer sentry-token"}

      case conn.request_path do
        "/api/0/projects/acme/checkout/issues/" ->
          conn = Plug.Conn.fetch_query_params(conn)
          assert conn.query_params["query"] == "is:unresolved"
          assert conn.query_params["environment"] == "production"

          Req.Test.json(conn, [
            %{
              "id" => "111",
              "shortId" => "CHECKOUT-1",
              "title" => "TypeError: total is undefined",
              "level" => "error",
              "status" => "unresolved",
              "count" => "42",
              "userCount" => 11,
              "firstSeen" => "2026-05-18T14:03:00Z",
              "lastSeen" => "2026-05-18T15:20:00Z",
              "culprit" => "checkout.total",
              "permalink" => "https://sentry.example.com/issues/111"
            },
            %{
              "id" => "222",
              "shortId" => "CHECKOUT-2",
              "title" => "RangeError: invalid time value",
              "level" => "warning",
              "status" => "unresolved",
              "count" => 3,
              "permalink" => "https://sentry.example.com/issues/222"
            }
          ])

        "/api/0/issues/111/events/latest/" ->
          Req.Test.json(conn, %{
            "eventID" => "event-111",
            "message" => "Cannot read properties of undefined",
            "dateCreated" => "2026-05-18T15:19:00Z"
          })

        "/api/0/issues/222/events/latest/" ->
          Req.Test.json(conn, %{
            "eventID" => "event-222",
            "message" => "Invalid time value",
            "dateCreated" => "2026-05-18T15:10:00Z"
          })
      end
    end)

    {:ok, integration} =
      Integrations.create_integration(%{
        name: "Checkout Errors",
        service_type: "sentry",
        token: "sentry-token",
        config_text: ~s({"org":"acme","project":"checkout","environment":"production","limit":5})
      })

    assert {:ok, run} =
             Integrations.poll_integration(integration,
               req_options: [plug: {Req.Test, BusterClaw.IntegrationHTTP}]
             )

    assert run.status == "ok"
    assert run.records_fetched == 1

    assert [document] = Library.list_documents()
    assert document.id == run.document_id
    assert document.name == "Sentry Issues Snapshot: checkout"
    assert document.tags == %{"items" => ["integration", "sentry", "issues", "monitoring"]}

    assert {:ok, body} = Library.read_raw_document(document)
    assert body =~ "# Sentry Issues Snapshot: checkout"
    assert body =~ "- Service: Sentry"
    assert body =~ "- Integration: Checkout Errors"
    assert body =~ "- Issues returned: 2"
    assert body =~ "### TypeError: total is undefined"
    assert body =~ "- Short ID: CHECKOUT-1"
    assert body =~ "- Count: 42"
    assert body =~ "Latest event sample"
    assert body =~ "Cannot read properties of undefined"

    integration = Integrations.get_integration!(integration.id)
    assert integration.last_status == "ok"
    assert is_nil(integration.last_error)
  end

  test "returns a run error when required Sentry config is missing" do
    {:ok, integration} =
      Integrations.create_integration(%{
        name: "Missing Project",
        service_type: "sentry",
        config_text: ~s({"org":"acme"})
      })

    assert {:error, run} = Integrations.poll_integration(integration)
    assert run.status == "error"
    assert run.error =~ "missing_config"
    assert [] = Library.list_documents()
  end

  test "stores signed Sentry webhook payloads as Library documents" do
    body =
      Jason.encode!(%{
        "action" => "issue.created",
        "data" => %{
          "issue" => %{
            "title" => "New production error",
            "level" => "error",
            "permalink" => "https://sentry.example.com/issues/333"
          }
        }
      })

    signature = hmac("webhook-secret", body)

    {:ok, integration} =
      Integrations.create_integration(%{
        name: "Sentry Webhooks",
        service_type: "sentry",
        webhook_secret: "webhook-secret",
        config_text: ~s({"org":"acme","project":"checkout"})
      })

    assert {:ok, run} =
             Integrations.handle_webhook(
               integration,
               [{"sentry-hook-signature", signature}],
               body
             )

    assert run.status == "ok"
    assert run.trigger == "webhook"
    assert run.records_fetched == 1

    assert [document] = Library.list_documents()
    assert document.name == "Sentry Webhook Snapshot: issue.created"
    assert document.tags == %{"items" => ["integration", "sentry", "webhook", "monitoring"]}

    assert {:ok, markdown} = Library.read_raw_document(document)
    assert markdown =~ "# Sentry Webhook Snapshot: issue.created"
    assert markdown =~ "- Issue: New production error"
    assert markdown =~ "## Payload Excerpt"
  end

  test "rejects invalid Sentry webhook signatures and records a failed run" do
    body = Jason.encode!(%{"action" => "issue.created"})

    {:ok, integration} =
      Integrations.create_integration(%{
        name: "Sentry Webhooks",
        service_type: "sentry",
        webhook_secret: "webhook-secret",
        config_text: ~s({"org":"acme","project":"checkout"})
      })

    assert {:error, run} =
             Integrations.handle_webhook(
               integration,
               [{"sentry-hook-signature", hmac("wrong-secret", body)}],
               body
             )

    assert run.status == "error"
    assert run.error =~ "unauthorized"
    assert [] = Library.list_documents()
  end

  defp hmac(secret, body) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end
end
