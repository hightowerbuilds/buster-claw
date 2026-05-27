defmodule BusterClaw.IntegrationsTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Integrations, Library, Providers}

  setup do
    Req.Test.verify_on_exit!()

    root =
      Path.join(
        System.tmp_dir!(),
        "buster-claw-integrations-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :library_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :library_root, previous)
      File.rm_rf(root)
    end)

    :ok
  end

  test "creates, updates, lists, and deletes integrations" do
    assert {:ok, integration} =
             Integrations.create_integration(%{
               name: "repo-activity",
               service_type: "github",
               token: "secret",
               config_text: ~s({"owner":"hightowerbuilds","repo":"buster-claw"})
             })

    assert integration.base_url == "https://api.github.com"
    assert integration.config == %{"owner" => "hightowerbuilds", "repo" => "buster-claw"}
    assert [listed] = Integrations.list_integrations()
    assert listed.id == integration.id

    assert {:ok, integration} =
             Integrations.update_integration(integration, %{
               enabled: false,
               polling_interval_minutes: 15
             })

    refute integration.enabled
    assert integration.polling_interval_minutes == 15

    assert {:ok, _integration} = Integrations.delete_integration(integration)
    assert [] = Integrations.list_integrations()
  end

  test "validates service type, unique name, polling interval, and config json" do
    assert {:error, changeset} =
             Integrations.create_integration(%{
               name: "bad",
               service_type: "bad",
               polling_interval_minutes: 0
             })

    assert %{service_type: [_], polling_interval_minutes: [_]} = errors_on(changeset)

    assert {:error, changeset} =
             Integrations.create_integration(%{
               name: "bad-json",
               service_type: "github",
               config_text: "[not a map]"
             })

    assert %{config_text: [_]} = errors_on(changeset)

    assert {:ok, _integration} =
             Integrations.create_integration(%{
               name: "analytics",
               service_type: "umami",
               base_url: "https://umami.example.com",
               config_text: ~s({"website_id":"site-id"})
             })

    assert {:error, changeset} =
             Integrations.create_integration(%{
               name: "analytics",
               service_type: "umami",
               base_url: "https://umami.example.com"
             })

    assert %{name: [_]} = errors_on(changeset)
  end

  test "polling missing GitHub config records run history and updates integration status" do
    assert {:ok, integration} =
             Integrations.create_integration(%{
               name: "repo-prod",
               service_type: "github",
               config_text: ~s({"owner":"acme"})
             })

    assert {:error, run} = Integrations.poll_integration(integration)
    assert run.integration_id == integration.id
    assert run.trigger == "manual"
    assert run.status == "error"
    assert run.records_fetched == 0
    assert run.error =~ "missing_config"

    integration = Integrations.get_integration!(integration.id)
    assert integration.last_status == "error"
    assert integration.last_error =~ "missing_config"

    assert [listed_run] = Integrations.list_runs_for_integration(integration)
    assert listed_run.id == run.id
  end

  test "polling disabled integrations records disabled run history" do
    assert {:ok, integration} =
             Integrations.create_integration(%{
               name: "disabled-repo",
               service_type: "github",
               enabled: false
             })

    assert {:error, run} = Integrations.poll_integration(integration)
    assert run.status == "error"
    assert run.error == "Integration is disabled"

    integration = Integrations.get_integration!(integration.id)
    assert integration.last_status == "disabled"
    assert integration.last_error == "Integration is disabled"
  end

  test "latest_documents returns integration tagged Library documents first" do
    integration_doc = raw_document!("GitHub Snapshot", ["integration", "github", "monitoring"])
    _other_doc = raw_document!("Regular Document", ["research"])

    assert [document] = Integrations.latest_documents()
    assert document.id == integration_doc.id
  end

  test "generate_monitoring_brief uses active provider and saves a monitoring report" do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "GitHub deploy snapshot"
      assert body =~ "Sentry issue snapshot"

      Req.Test.json(conn, %{
        choices: [
          %{
            message: %{
              content: "## Executive summary\n\nInvestigate the failed deploy and new errors."
            }
          }
        ]
      })
    end)

    {:ok, provider} =
      Providers.create_provider(%{
        name: "openai",
        type: "openai",
        model: "gpt-5.4",
        api_key: "secret",
        active: true
      })

    _github = raw_document!("GitHub deploy snapshot", ["integration", "github", "activity"])
    _sentry = raw_document!("Sentry issue snapshot", ["integration", "sentry", "issues"])
    source_document_ids = Integrations.latest_documents(5) |> Enum.map(& &1.id)

    assert {:ok, report} = Integrations.generate_monitoring_brief(limit: 5)
    assert report.provider_id == provider.id
    assert report.model == "gpt-5.4"
    assert report.tags["items"] == ["monitoring", "brief", "consultation"]
    assert report.tags["monitoring"]["source_document_ids"] == source_document_ids

    report_path = Library.absolute_artifact_path(report.artifact_path)
    assert File.exists?(report_path)
    assert File.read!(report_path) =~ "# Monitoring Brief"
    assert File.read!(report_path) =~ "Investigate the failed deploy and new errors."
  end

  test "generate_monitoring_brief can use a provider override" do
    Req.Test.stub(BusterClaw.ProviderHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "override-model"
      assert body =~ "GitHub deploy snapshot"

      Req.Test.json(conn, %{
        choices: [
          %{
            message: %{
              content: "## Executive summary\n\nOverride provider generated this brief."
            }
          }
        ]
      })
    end)

    {:ok, _active_provider} =
      Providers.create_provider(%{
        name: "active-provider",
        type: "openai",
        model: "active-model",
        api_key: "secret",
        active: true
      })

    {:ok, override_provider} =
      Providers.create_provider(%{
        name: "override-provider",
        type: "openai",
        model: "override-model",
        api_key: "secret",
        active: false
      })

    _github = raw_document!("GitHub deploy snapshot", ["integration", "github", "activity"])

    assert {:ok, report} =
             Integrations.generate_monitoring_brief(provider_id: "#{override_provider.id}")

    assert report.provider_id == override_provider.id
    assert report.model == "override-model"
    assert report.tags["monitoring"]["provider"] == "override-provider"
  end

  test "generate_monitoring_brief returns clear errors without documents or provider" do
    assert {:error, :no_integration_documents} = Integrations.generate_monitoring_brief()

    _document = raw_document!("Sentry issue snapshot", ["integration", "sentry", "issues"])

    assert {:error, :no_active_provider} = Integrations.generate_monitoring_brief()
    assert {:error, :provider_not_found} = Integrations.generate_monitoring_brief(provider_id: -1)
  end

  defp raw_document!(name, tags) do
    filename =
      name
      |> String.downcase()
      |> String.replace(" ", "-")
      |> Kernel.<>(".md")

    assert {:ok, document} =
             Library.save_raw_document(%{
               date: ~D[2026-05-18],
               filename: filename,
               name: name,
               source_url: "https://example.com/#{filename}",
               tags: tags,
               content: "# #{name}\n\nImportant operational source material."
             })

    document
  end
end
