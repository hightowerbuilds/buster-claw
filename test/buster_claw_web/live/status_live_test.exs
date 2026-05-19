defmodule BusterClawWeb.StatusLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Providers

  test "GET / renders the home shell", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Buster Claw"
    assert response =~ "Models"
    assert response =~ "Active key"
    # Sidebar nav still surfaces every section
    assert response =~ "Webhooks"
    assert response =~ "Hooks"
  end

  test "GET /chat renders the chat shell", %{conn: conn} do
    conn = get(conn, ~p"/chat")
    response = html_response(conn, 200)

    assert response =~ "Supervised local chat session"
    assert response =~ "Chat"
  end

  describe "activate_provider" do
    test "activating provider B deactivates provider A via the context", %{conn: conn} do
      {:ok, a} =
        Providers.create_provider(%{name: "a-local", type: "ollama", model: "llama3"})

      {:ok, _} = Providers.set_active_provider(a)

      {:ok, b} =
        Providers.create_provider(%{name: "b-local", type: "ollama", model: "llama3"})

      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("form[phx-change='activate_provider']", %{provider: %{active_id: "#{b.id}"}})
      |> render_change()

      refute Providers.get_provider!(a.id).active
      assert Providers.get_provider!(b.id).active
      assert Providers.active_provider().id == b.id
    end

    test "selecting the empty option clears the active provider", %{conn: conn} do
      {:ok, a} =
        Providers.create_provider(%{name: "to-clear", type: "ollama", model: "llama3"})

      {:ok, _} = Providers.set_active_provider(a)
      assert Providers.active_provider().id == a.id

      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("form[phx-change='activate_provider']", %{provider: %{active_id: ""}})
      |> render_change()

      assert Providers.active_provider() == nil
      refute Providers.get_provider!(a.id).active
    end
  end
end
