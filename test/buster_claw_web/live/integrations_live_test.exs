defmodule BusterClawWeb.IntegrationsLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Integrations

  test "renders configured integrations and recent runs", %{conn: conn} do
    {:ok, integration} =
      Integrations.create_integration(%{
        name: "Repo Activity",
        service_type: "sentry",
        config_text: ~s({"org":"hightowerbuilds"})
      })

    {:error, _run} = Integrations.poll_integration(integration)

    {:ok, _view, html} = live(conn, ~p"/integrations")

    assert html =~ "Integrations"
    assert html =~ "Repo Activity"
    assert html =~ "sentry"
    assert html =~ "Recent runs"
    assert html =~ "missing_config"
  end

  test "adds, edits, toggles, polls, and deletes an integration from the UI", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/integrations")
    assert html =~ "No integrations configured yet"

    html =
      view
      |> form("#integration-form", %{
        integration: %{
          name: "Traffic",
          service_type: "umami",
          base_url: "https://umami.example.com",
          token: "secret",
          config_text: ~s({"website_id":"site-id"}),
          polling_interval_minutes: "30",
          enabled: "true"
        }
      })
      |> render_submit()

    assert html =~ "Integration saved."
    assert html =~ "Traffic"
    [integration] = Integrations.list_integrations()
    assert integration.service_type == "umami"
    assert integration.config == %{"website_id" => "site-id"}

    html =
      view
      |> element("button[phx-click='edit'][phx-value-id='#{integration.id}']")
      |> render_click()

    assert html =~ "Edit Integration"

    html =
      view
      |> form("#integration-form", %{
        integration: %{
          name: "Traffic Prod",
          service_type: "umami",
          base_url: "https://umami.example.com",
          token: "secret",
          config_text: ~s({"website_id":"prod-site"}),
          polling_interval_minutes: "15",
          enabled: "true"
        }
      })
      |> render_submit()

    assert html =~ "Traffic Prod"
    [integration] = Integrations.list_integrations()
    assert integration.polling_interval_minutes == 15

    html =
      view
      |> element("button[phx-click='toggle'][phx-value-id='#{integration.id}']")
      |> render_click()

    assert html =~ "disabled"
    refute Integrations.get_integration!(integration.id).enabled

    html =
      view
      |> element("button[phx-click='poll'][phx-value-id='#{integration.id}']")
      |> render_click()

    assert html =~ "Poll failed: Integration is disabled"

    assert [_run] =
             Integrations.list_runs_for_integration(Integrations.get_integration!(integration.id))

    html =
      view
      |> element("button[phx-click='delete'][phx-value-id='#{integration.id}']")
      |> render_click()

    assert html =~ "No integrations configured yet"
    assert [] = Integrations.list_integrations()
  end

  test "poll all runs each configured integration", %{conn: conn} do
    {:ok, _github} =
      Integrations.create_integration(%{
        name: "Repo Activity",
        service_type: "github"
      })

    {:ok, _sentry} =
      Integrations.create_integration(%{
        name: "Errors",
        service_type: "sentry"
      })

    {:ok, view, _html} = live(conn, ~p"/integrations")

    html =
      view
      |> element("#integrations-poll-all")
      |> render_click()

    assert html =~ "Poll all completed: 0 ok, 2 failed."
    assert length(Integrations.list_runs()) == 2
  end
end
