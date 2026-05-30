defmodule BusterClawWeb.RuntimeLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Providers

  test "GET /runtime renders runtime control with the advanced tabs", %{conn: conn} do
    conn = get(conn, ~p"/runtime")
    response = html_response(conn, 200)

    assert response =~ "Models"
    assert response =~ "Active key"
    assert response =~ ~s(id="advanced-tabs")
    assert response =~ ~s(id="advanced-tab-runtime")
  end

  test "activating provider B deactivates provider A via the context", %{conn: conn} do
    {:ok, a} = Providers.create_provider(%{name: "a-local", type: "ollama", model: "llama3"})
    {:ok, _} = Providers.set_active_provider(a)
    {:ok, b} = Providers.create_provider(%{name: "b-local", type: "ollama", model: "llama3"})

    {:ok, view, _html} = live(conn, ~p"/runtime")

    view
    |> form("form[phx-change='activate_provider']", %{provider: %{active_id: "#{b.id}"}})
    |> render_change()

    refute Providers.get_provider!(a.id).active
    assert Providers.get_provider!(b.id).active
    assert Providers.active_provider().id == b.id
  end

  test "submitting the add-provider form creates and lists a provider", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/runtime")

    html =
      view
      |> form("form[phx-submit='add_provider']", %{
        provider: %{
          name: "OpenRouter Test",
          type: "openrouter",
          model: "openai/gpt-4o",
          api_key: "secret"
        }
      })
      |> render_submit()

    assert html =~ "Saved OpenRouter Test."
    assert html =~ "OpenRouter Test"
    assert [%{name: "OpenRouter Test"}] = Providers.list_providers()
  end

  test "delete button removes a provider", %{conn: conn} do
    {:ok, p} = Providers.create_provider(%{name: "to-delete", type: "ollama", model: "llama3"})

    {:ok, view, _html} = live(conn, ~p"/runtime")

    html =
      view
      |> element("button[phx-click='delete_provider'][phx-value-id='#{p.id}']")
      |> render_click()

    assert html =~ "Deleted to-delete."
    assert [] = Providers.list_providers()
  end

  test "selecting the empty option clears the active provider", %{conn: conn} do
    {:ok, a} = Providers.create_provider(%{name: "to-clear", type: "ollama", model: "llama3"})
    {:ok, _} = Providers.set_active_provider(a)
    assert Providers.active_provider().id == a.id

    {:ok, view, _html} = live(conn, ~p"/runtime")

    view
    |> form("form[phx-change='activate_provider']", %{provider: %{active_id: ""}})
    |> render_change()

    assert Providers.active_provider() == nil
    refute Providers.get_provider!(a.id).active
  end
end
