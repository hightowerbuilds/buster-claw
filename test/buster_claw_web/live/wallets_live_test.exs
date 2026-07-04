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
