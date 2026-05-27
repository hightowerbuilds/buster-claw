defmodule BusterClawWeb.StatusLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Calendar
  alias BusterClaw.Google
  alias BusterClaw.LocalTime
  alias BusterClaw.Providers

  test "GET / renders the home shell", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Buster Claw"
    assert response =~ ~s(<details id="home-google-workspace-login")
    assert response =~ ~s(href="/gws")
    assert response =~ "Models"
    assert response =~ "Active key"
    assert response =~ ~s(href="/advanced")
    refute response =~ ~s(href="/webhooks")
    refute response =~ ~s(href="/hooks")
    refute response =~ ~s(href="/integrations")
    refute response =~ ~s(href="/mcp")
    refute response =~ ~s(href="/delivery")
  end

  test "home Google Workspace form saves an account and prepares sign-in", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#google-account-form", %{
        google_account: %{
          email: "me@example.com",
          client_id: "client-id",
          client_secret: "client-secret"
        }
      })
      |> render_submit()

    assert html =~ ~s(id="google-oauth-link")
    assert html =~ ~s(id="home-google-workspace-login" open)
    assert html =~ "accounts.google.com"
    assert [account] = Google.list_accounts()
    assert account.email == "me@example.com"
    assert account.client_id == "client-id"
    assert account.scopes =~ "gmail.readonly"
  end

  test "GET / renders today's calendar events", %{conn: conn} do
    today = LocalTime.today()

    {:ok, _event} =
      Calendar.create_event(%{
        event_id: "home-today-event",
        date: today,
        start_time: ~T[09:30:00],
        title: "Home page planning block",
        notes: "Visible on the daily agenda.",
        color: "work"
      })

    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ ~s(id="home-daily-calendar")
    assert response =~ "Home page planning block"
    assert response =~ "09:30"
  end

  test "GET / uses the app-local date for the daily calendar", %{conn: conn} do
    previous = Application.get_env(:buster_claw, :local_today)
    Application.put_env(:buster_claw, :local_today, ~D[2026-05-26])

    on_exit(fn ->
      if previous do
        Application.put_env(:buster_claw, :local_today, previous)
      else
        Application.delete_env(:buster_claw, :local_today)
      end
    end)

    {:ok, _event} =
      Calendar.create_event(%{
        event_id: "home-local-today",
        date: ~D[2026-05-26],
        title: "Local today event"
      })

    {:ok, _event} =
      Calendar.create_event(%{
        event_id: "home-utc-tomorrow",
        date: ~D[2026-05-27],
        title: "UTC tomorrow event"
      })

    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    assert response =~ "Local today event"
    refute response =~ "UTC tomorrow event"
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

    test "submitting the add-provider form creates and lists a provider", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

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
      {:ok, p} =
        Providers.create_provider(%{name: "to-delete", type: "ollama", model: "llama3"})

      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> element("button[phx-click='delete_provider'][phx-value-id='#{p.id}']")
        |> render_click()

      assert html =~ "Deleted to-delete."
      assert [] = Providers.list_providers()
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
