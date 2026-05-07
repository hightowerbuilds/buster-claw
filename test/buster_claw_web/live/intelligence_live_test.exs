defmodule BusterClawWeb.IntelligenceLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Providers

  test "renders configured providers", %{conn: conn} do
    {:ok, _provider} =
      Providers.create_provider(%{
        name: "Local",
        type: "ollama",
        model: "llama3"
      })

    {:ok, _view, html} = live(conn, ~p"/intelligence")

    assert html =~ "Intelligence"
    assert html =~ "Local"
    assert html =~ "llama3"
  end

  test "adds, activates, and deletes a provider from the UI", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/intelligence")
    assert html =~ "No providers configured yet"

    html =
      view
      |> form("form", %{
        provider: %{
          name: "OpenRouter",
          type: "openrouter",
          model: "openai/gpt-5.4",
          api_key: "secret"
        }
      })
      |> render_submit()

    assert html =~ "Provider added."
    assert html =~ "OpenRouter"
    [provider] = Providers.list_providers()

    html =
      view
      |> element("button[phx-click='activate_provider'][phx-value-id='#{provider.id}']")
      |> render_click()

    assert html =~ "OpenRouter is active."
    assert Providers.active_provider().id == provider.id

    html =
      view
      |> element("button[phx-click='delete_provider'][phx-value-id='#{provider.id}']")
      |> render_click()

    assert html =~ "No providers configured yet"
    assert [] = Providers.list_providers()
  end
end
