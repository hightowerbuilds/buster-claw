defmodule BusterClawWeb.WalletsLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Wallets

  test "creates a wallet from the UI and opens its ledger", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/wallets")
    assert html =~ "Wallets"
    assert html =~ "No wallets yet"

    html =
      view
      |> form("#wallet-form", %{wallet: %{name: "Acme Ops", type: "business", currency: "USD"}})
      |> render_submit()

    assert html =~ "Acme Ops"
    assert html =~ ~r/created/
    assert [wallet] = Wallets.list_wallets()
    assert wallet.name == "Acme Ops"

    # creating selects it, revealing the add-transaction form
    assert render(view) =~ "Add transaction"
  end

  test "adds income and expense and shows the running balance", %{conn: conn} do
    {:ok, wallet} = Wallets.create_wallet(%{name: "Acme", type: "business"})
    {:ok, view, _html} = live(conn, ~p"/wallets")

    view |> element("#wallet-#{wallet.id}") |> render_click()

    view
    |> form("#transaction-form", %{
      transaction: %{kind: "income", amount: "500", category: "sales", description: "invoice"}
    })
    |> render_submit()

    view
    |> form("#transaction-form", %{
      transaction: %{kind: "expense", amount: "125.50", category: "tools"}
    })
    |> render_submit()

    assert Wallets.get_wallet!(wallet.id).balance_cents == 37_450
    html = render(view)
    assert html =~ "invoice"
    assert html =~ "$374.50"
  end

  test "personal wallet shows a budget panel", %{conn: conn} do
    {:ok, business} = Wallets.create_wallet(%{name: "Biz", type: "business"})
    {:ok, personal} = Wallets.create_wallet(%{name: "Mine", type: "personal"})
    {:ok, view, _html} = live(conn, ~p"/wallets")

    view |> element("#wallet-#{business.id}") |> render_click()
    refute render(view) =~ "Save Budget"

    view |> element("#wallet-#{personal.id}") |> render_click()
    html = render(view)
    assert html =~ "Budget"
    assert html =~ "Save Budget"
  end

  test "adds a polling feed from the wallet detail UI", %{conn: conn} do
    {:ok, wallet} = Wallets.create_wallet(%{name: "Acme", type: "business"})
    {:ok, view, _html} = live(conn, ~p"/wallets")

    view |> element("#wallet-#{wallet.id}") |> render_click()

    html =
      view
      |> form("#feed-form", %{
        feed: %{kind: "market", target: "AAPL", polling_interval_minutes: "30"}
      })
      |> render_submit()

    assert html =~ "Feed added."
    assert html =~ "AAPL"
    assert [feed] = Wallets.list_feeds(wallet)
    assert feed.kind == "market"
    assert feed.config == %{"symbol" => "AAPL"}
    assert feed.polling_interval_minutes == 30
  end

  test "busterclaw template wallet shows the running-cost panel and saves model costs",
       %{conn: conn} do
    {:ok, _vm} =
      BusterClaw.Telephony.record_event(
        %{
          direction: "inbound",
          kind: "voicemail",
          from_number: "+15033412655",
          to_number: "+13603646763",
          twilio_sid: "RE#{System.unique_integer([:positive])}",
          occurred_at: DateTime.utc_now() |> DateTime.truncate(:second),
          cost_micros: 250_000,
          cost_synced_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        observe: false
      )

    {:ok, view, _html} = live(conn, ~p"/wallets")

    view
    |> form("#wallet-form", %{
      wallet: %{name: "Running Costs", type: "business", template: "busterclaw", currency: "USD"}
    })
    |> render_submit()

    html = render(view)
    assert html =~ "BusterClaw running costs"
    assert html =~ "+13603646763"
    # $0.25 of phone spend, from the 250_000 micro-USD voicemail.
    assert html =~ "$0.25"

    html =
      view
      |> form("#model-costs-form", %{
        model_costs: %{anthropic: "20", openai: "", opencode: "10"}
      })
      |> render_submit()

    assert html =~ "Model costs saved."
    assert html =~ "$30.00"

    [wallet] = Wallets.list_wallets()
    assert wallet.model_costs == %{"anthropic" => 2000, "opencode" => 1000}
  end

  test "a plain (non-template) wallet has no running-cost panel", %{conn: conn} do
    {:ok, wallet} = Wallets.create_wallet(%{name: "Plain", type: "business"})
    {:ok, view, _html} = live(conn, ~p"/wallets")

    view |> element("#wallet-#{wallet.id}") |> render_click()
    refute render(view) =~ "BusterClaw running costs"
  end

  test "deletes a wallet from the UI", %{conn: conn} do
    {:ok, wallet} = Wallets.create_wallet(%{name: "Temp", type: "business"})
    {:ok, view, _html} = live(conn, ~p"/wallets")

    view |> element("#wallet-#{wallet.id}") |> render_click()

    html =
      view
      |> element("button[phx-click='delete_wallet'][phx-value-id='#{wallet.id}']")
      |> render_click()

    assert html =~ "Wallet deleted."
    assert [] = Wallets.list_wallets()
  end

  test "delete uses the app-owned confirm, not the native window.confirm gate",
       %{conn: conn} do
    # Native `data-confirm` gates the event behind window.confirm(), a no-op that
    # returns false in the Tauri/WKWebView shell — so the delete never fired. The
    # button must carry `data-claw-confirm` (handled by our JS interceptor) and
    # NOT `data-confirm`, or the whole path silently dies in the real app again.
    {:ok, wallet} = Wallets.create_wallet(%{name: "Temp", type: "business"})
    {:ok, view, _html} = live(conn, ~p"/wallets")

    view |> element("#wallet-#{wallet.id}") |> render_click()
    html = render(view)

    assert html =~ ~s(data-claw-confirm="Delete this wallet and all its transactions?")
    refute html =~ "data-confirm="
  end

  test "a crafted non-integer wallet id does not crash the LiveView", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/wallets")

    # A malformed phx-value-id would raise on Wallets.get_wallet!/1; the guarded
    # handlers must swallow it and keep the view alive.
    assert render_click(view, "open", %{"id" => "not-a-number"})
    assert render_click(view, "delete_wallet", %{"id" => "not-a-number"})
    assert Process.alive?(view.pid)
  end

  test "an unexpected topic message does not crash the LiveView", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/wallets")

    send(view.pid, {:totally_unexpected, :shape})
    assert Process.alive?(view.pid)
    assert render(view) =~ "Wallets"
  end
end
