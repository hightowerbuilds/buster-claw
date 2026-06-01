defmodule BusterClaw.Integrations.GitHubTest do
  use BusterClaw.DataCase

  alias BusterClaw.Integrations
  alias BusterClaw.Library

  setup do
    Req.Test.verify_on_exit!()

    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-github-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, previous)
      File.rm_rf(root)
    end)

    :ok
  end

  test "polls GitHub repository activity and saves a Library snapshot document" do
    Req.Test.stub(BusterClaw.IntegrationHTTP, fn conn ->
      assert List.keyfind(conn.req_headers, "authorization", 0) ==
               {"authorization", "Bearer github-token"}

      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/repos/acme/checkout/commits" ->
          assert conn.query_params["sha"] == "main"

          Req.Test.json(conn, [
            %{
              "sha" => "abcdef123456",
              "html_url" => "https://github.com/acme/checkout/commit/abcdef1",
              "commit" => %{
                "message" => "Fix checkout total\n\nBody",
                "author" => %{"name" => "Ada"}
              }
            }
          ])

        "/repos/acme/checkout/pulls" ->
          case conn.query_params["state"] do
            "open" ->
              Req.Test.json(conn, [
                %{
                  "number" => 12,
                  "title" => "Improve payment copy",
                  "html_url" => "https://github.com/acme/checkout/pull/12",
                  "user" => %{"login" => "grace"}
                }
              ])

            "closed" ->
              Req.Test.json(conn, [
                %{
                  "number" => 10,
                  "title" => "Ship checkout v2",
                  "merged_at" => "2026-05-18T10:00:00Z",
                  "html_url" => "https://github.com/acme/checkout/pull/10",
                  "user" => %{"login" => "alan"}
                },
                %{
                  "number" => 9,
                  "title" => "Closed without merge",
                  "merged_at" => nil,
                  "html_url" => "https://github.com/acme/checkout/pull/9",
                  "user" => %{"login" => "linus"}
                }
              ])
          end

        "/repos/acme/checkout/issues" ->
          Req.Test.json(conn, [
            %{
              "number" => 4,
              "title" => "Investigate failed card retries",
              "html_url" => "https://github.com/acme/checkout/issues/4",
              "user" => %{"login" => "margaret"}
            },
            %{
              "number" => 12,
              "title" => "PR also appears as issue",
              "pull_request" => %{},
              "html_url" => "https://github.com/acme/checkout/pull/12",
              "user" => %{"login" => "grace"}
            }
          ])

        "/repos/acme/checkout/actions/runs" ->
          Req.Test.json(conn, %{
            "workflow_runs" => [
              %{
                "name" => "CI",
                "status" => "completed",
                "conclusion" => "failure",
                "head_branch" => "main",
                "html_url" => "https://github.com/acme/checkout/actions/runs/1"
              }
            ]
          })

        "/repos/acme/checkout/releases" ->
          Req.Test.json(conn, [
            %{
              "tag_name" => "v2.0.0",
              "name" => "Checkout v2",
              "html_url" => "https://github.com/acme/checkout/releases/tag/v2.0.0"
            }
          ])
      end
    end)

    {:ok, integration} =
      Integrations.create_integration(%{
        name: "Checkout Repo",
        service_type: "github",
        token: "github-token",
        config_text:
          ~s({"owner":"acme","repo":"checkout","branch":"main","include_workflows":true,"include_issues":true,"limit":5})
      })

    assert {:ok, run} =
             Integrations.poll_integration(integration,
               req_options: [plug: {Req.Test, BusterClaw.IntegrationHTTP}]
             )

    assert run.status == "ok"
    assert run.records_fetched == 1

    assert [document] = Library.list_documents()
    assert document.id == run.document_id
    assert document.name == "GitHub Activity Snapshot: acme/checkout"
    assert document.tags == %{"items" => ["integration", "github", "activity", "monitoring"]}

    assert {:ok, body} = Library.read_raw_document(document)
    assert body =~ "# GitHub Activity Snapshot: acme/checkout"
    assert body =~ "- Service: GitHub"
    assert body =~ "- Recent commits: 1"
    assert body =~ "- Workflow runs: 1 (1 failed or cancelled)"
    assert body =~ "## Recent Commits"
    assert body =~ "abcdef1 Fix checkout total by Ada"
    assert body =~ "## Recently Merged Pull Requests"
    assert body =~ "#10 Ship checkout v2"
    assert body =~ "## Open Issues"
    assert body =~ "#4 Investigate failed card retries"
    refute body =~ "PR also appears as issue"

    integration = Integrations.get_integration!(integration.id)
    assert integration.last_status == "ok"
    assert is_nil(integration.last_error)
  end

  test "returns a run error when required GitHub config is missing" do
    {:ok, integration} =
      Integrations.create_integration(%{
        name: "Missing Repo",
        service_type: "github",
        config_text: ~s({"owner":"acme"})
      })

    assert {:error, run} = Integrations.poll_integration(integration)
    assert run.status == "error"
    assert run.error =~ "missing_config"
    assert [] = Library.list_documents()
  end

  test "dedupes repeated polling snapshots when enabled" do
    stub_empty_github_poll()

    {:ok, integration} =
      Integrations.create_integration(%{
        name: "Checkout Repo Dedupe",
        service_type: "github",
        config_text:
          ~s({"owner":"acme","repo":"checkout","include_workflows":true,"include_issues":true,"dedupe_poll_snapshots":true,"dedupe_window_days":30})
      })

    assert {:ok, first_run} =
             Integrations.poll_integration(integration,
               req_options: [plug: {Req.Test, BusterClaw.IntegrationHTTP}]
             )

    assert first_run.status == "ok"
    assert first_run.document_id
    assert first_run.metadata["dedupe"]["enabled"] == true
    assert first_run.metadata["dedupe"]["saved"] == 1
    assert first_run.metadata["dedupe"]["skipped"] == []

    assert [document] = Library.list_documents()

    assert {:ok, second_run} =
             Integrations.poll_integration(integration,
               req_options: [plug: {Req.Test, BusterClaw.IntegrationHTTP}]
             )

    assert second_run.status == "ok"
    assert is_nil(second_run.document_id)
    assert second_run.records_fetched == 1
    assert second_run.metadata["documents"] == []
    assert second_run.metadata["dedupe"]["enabled"] == true
    assert second_run.metadata["dedupe"]["saved"] == 0

    assert [
             %{
               "name" => "GitHub Activity Snapshot: acme/checkout",
               "source_url" => "https://github.com/acme/checkout",
               "duplicate_of" => duplicate_path
             }
           ] = second_run.metadata["dedupe"]["skipped"]

    assert duplicate_path == document.artifact_path
    assert [remaining_document] = Library.list_documents()
    assert remaining_document.id == document.id
  end

  test "stores signed GitHub webhook payloads as Library documents" do
    body =
      Jason.encode!(%{
        "action" => "completed",
        "workflow_run" => %{
          "name" => "CI",
          "html_url" => "https://github.com/acme/checkout/actions/runs/1"
        },
        "repository" => %{
          "full_name" => "acme/checkout",
          "html_url" => "https://github.com/acme/checkout"
        },
        "authorization" => "Bearer payload-secret",
        "hook" => %{"secret" => "payload-secret", "signature" => "payload-signature"},
        "installation" => %{"access_token" => "payload-token"},
        "sender" => %{"login" => "octocat"}
      })

    {:ok, integration} =
      Integrations.create_integration(%{
        name: "GitHub Webhooks",
        service_type: "github",
        webhook_secret: "webhook-secret",
        config_text: ~s({"owner":"acme","repo":"checkout"})
      })

    assert {:ok, run} =
             Integrations.handle_webhook(
               integration,
               [{"x-hub-signature-256", "sha256=#{hmac("webhook-secret", body)}"}],
               body
             )

    assert run.status == "ok"
    assert run.trigger == "webhook"
    assert run.records_fetched == 1

    assert [document] = Library.list_documents()
    assert document.name == "GitHub Webhook Snapshot: workflow_run.completed"
    assert document.tags == %{"items" => ["integration", "github", "webhook", "monitoring"]}
    assert Library.get_document!(document.id).status == "fetched"

    assert {:ok, markdown} = Library.read_raw_document(document)
    assert markdown =~ "# GitHub Webhook Snapshot: workflow_run.completed"
    assert markdown =~ "- Repository: acme/checkout"
    assert markdown =~ "- Sender: octocat"
    assert markdown =~ "## Payload Excerpt"
    assert markdown =~ "Retention: redacted excerpt"
    assert markdown =~ "[redacted]"
    refute markdown =~ "payload-secret"
    refute markdown =~ "payload-signature"
    refute markdown =~ "payload-token"
  end

  test "omits webhook payload excerpts when retention is disabled" do
    body =
      Jason.encode!(%{
        "action" => "completed",
        "workflow_run" => %{
          "name" => "CI",
          "html_url" => "https://github.com/acme/checkout/actions/runs/1"
        },
        "repository" => %{
          "full_name" => "acme/checkout",
          "html_url" => "https://github.com/acme/checkout"
        },
        "authorization" => "Bearer payload-secret",
        "sender" => %{"login" => "octocat"}
      })

    {:ok, integration} =
      Integrations.create_integration(%{
        name: "GitHub Webhooks No Payload",
        service_type: "github",
        webhook_secret: "webhook-secret",
        config_text: ~s({"owner":"acme","repo":"checkout","webhook_payload_excerpt":false})
      })

    assert {:ok, run} =
             Integrations.handle_webhook(
               integration,
               [{"x-hub-signature-256", "sha256=#{hmac("webhook-secret", body)}"}],
               body
             )

    assert run.status == "ok"

    assert [document] = Library.list_documents()
    assert {:ok, markdown} = Library.read_raw_document(document)
    assert markdown =~ "# GitHub Webhook Snapshot: workflow_run.completed"
    assert markdown =~ "- Repository: acme/checkout"
    refute markdown =~ "## Payload Excerpt"
    refute markdown =~ "payload-secret"
  end

  test "rejects invalid GitHub webhook signatures and records a failed run" do
    body = Jason.encode!(%{"action" => "opened", "issue" => %{"title" => "Bug"}})

    {:ok, integration} =
      Integrations.create_integration(%{
        name: "GitHub Webhooks",
        service_type: "github",
        webhook_secret: "webhook-secret",
        config_text: ~s({"owner":"acme","repo":"checkout"})
      })

    assert {:error, run} =
             Integrations.handle_webhook(
               integration,
               [{"x-hub-signature-256", "sha256=#{hmac("wrong-secret", body)}"}],
               body
             )

    assert run.status == "error"
    assert run.error =~ "unauthorized"
    assert [] = Library.list_documents()
  end

  defp hmac(secret, body) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp stub_empty_github_poll do
    Req.Test.stub(BusterClaw.IntegrationHTTP, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/repos/acme/checkout/commits" ->
          Req.Test.json(conn, [])

        "/repos/acme/checkout/pulls" ->
          assert conn.query_params["state"] in ["open", "closed"]
          Req.Test.json(conn, [])

        "/repos/acme/checkout/issues" ->
          Req.Test.json(conn, [])

        "/repos/acme/checkout/actions/runs" ->
          Req.Test.json(conn, %{"workflow_runs" => []})

        "/repos/acme/checkout/releases" ->
          Req.Test.json(conn, [])
      end
    end)
  end
end
