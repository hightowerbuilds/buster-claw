defmodule BusterClaw.WalletsTest do
  use BusterClaw.DataCase

  alias BusterClaw.Wallets

  defp wallet!(attrs \\ %{}) do
    {:ok, wallet} =
      Wallets.create_wallet(Map.merge(%{name: "Acme Ops", type: "business"}, attrs))

    wallet
  end

  test "creates, updates, lists, and deletes wallets" do
    assert {:ok, wallet} = Wallets.create_wallet(%{name: "Acme Ops", type: "business"})
    assert wallet.currency == "USD"
    assert wallet.balance_cents == 0
    assert [listed] = Wallets.list_wallets()
    assert listed.id == wallet.id

    assert {:ok, wallet} = Wallets.update_wallet(wallet, %{name: "Acme Inc"})
    assert wallet.name == "Acme Inc"

    assert {:ok, _} = Wallets.delete_wallet(wallet)
    assert [] = Wallets.list_wallets()
  end

  test "validates type and currency" do
    assert {:error, changeset} = Wallets.create_wallet(%{name: "Bad", type: "crypto"})
    assert %{type: ["is invalid"]} = errors_on(changeset)

    assert {:error, changeset} =
             Wallets.create_wallet(%{name: "Bad", type: "business", currency: "DOLLARS"})

    assert %{currency: _} = errors_on(changeset)
  end

  test "adding transactions recomputes the running balance" do
    wallet = wallet!()

    assert {:ok, _} =
             Wallets.add_transaction(wallet, %{
               kind: "income",
               amount_cents: 50_000,
               occurred_on: ~D[2026-06-01]
             })

    assert {:ok, _} =
             Wallets.add_transaction(wallet, %{
               kind: "expense",
               amount_cents: 12_500,
               occurred_on: ~D[2026-06-02]
             })

    assert Wallets.get_wallet!(wallet.id).balance_cents == 37_500
    assert length(Wallets.list_transactions(wallet)) == 2
  end

  test "deleting a transaction recomputes the balance" do
    wallet = wallet!()

    {:ok, income} =
      Wallets.add_transaction(wallet, %{
        kind: "income",
        amount_cents: 10_000,
        occurred_on: ~D[2026-06-01]
      })

    {:ok, _} =
      Wallets.add_transaction(wallet, %{
        kind: "expense",
        amount_cents: 4_000,
        occurred_on: ~D[2026-06-01]
      })

    assert Wallets.get_wallet!(wallet.id).balance_cents == 6_000

    {:ok, _} = Wallets.delete_transaction(income)
    assert Wallets.get_wallet!(wallet.id).balance_cents == -4_000
  end

  test "rejects non-positive transaction amounts" do
    wallet = wallet!()

    assert {:error, changeset} =
             Wallets.add_transaction(wallet, %{
               kind: "income",
               amount_cents: 0,
               occurred_on: ~D[2026-06-01]
             })

    assert %{amount_cents: _} = errors_on(changeset)
  end

  test "budget upsert and month-scoped summary" do
    wallet = wallet!(%{type: "personal"})

    {:ok, _} =
      Wallets.add_transaction(wallet, %{
        kind: "income",
        amount_cents: 300_000,
        occurred_on: ~D[2026-06-10]
      })

    {:ok, _} =
      Wallets.add_transaction(wallet, %{
        kind: "expense",
        amount_cents: 100_000,
        occurred_on: ~D[2026-06-15]
      })

    # different month — must not count toward June
    {:ok, _} =
      Wallets.add_transaction(wallet, %{
        kind: "expense",
        amount_cents: 99_999,
        occurred_on: ~D[2026-05-15]
      })

    assert {:ok, _} =
             Wallets.upsert_budget(wallet, %{
               month: "2026-06",
               income_target_cents: 250_000,
               expense_target_cents: 150_000
             })

    # upsert again updates the same row
    assert {:ok, _} =
             Wallets.upsert_budget(wallet, %{month: "2026-06", income_target_cents: 260_000})

    assert length(Wallets.list_budgets(wallet)) == 1

    summary = Wallets.budget_summary(wallet, "2026-06")
    assert summary.income_actual_cents == 300_000
    assert summary.expense_actual_cents == 100_000
    assert summary.savings_actual_cents == 200_000
    assert summary.income_target_cents == 260_000
  end

  test "feed CRUD and validation" do
    wallet = wallet!()

    assert {:ok, feed} =
             Wallets.create_feed(wallet, %{kind: "market", config: %{"symbol" => "AAPL"}})

    assert feed.kind == "market"
    assert [listed] = Wallets.list_feeds(wallet)
    assert listed.id == feed.id

    # market feed requires a symbol
    assert {:error, changeset} = Wallets.create_feed(wallet, %{kind: "market", config: %{}})
    assert %{config: _} = errors_on(changeset)

    # url feed requires a url
    assert {:error, _} = Wallets.create_feed(wallet, %{kind: "url", config: %{}})

    # gmail feed needs no config
    assert {:ok, _} = Wallets.create_feed(wallet, %{kind: "gmail", config: %{}})

    assert {:ok, _} = Wallets.delete_feed(feed)
  end

  test "broadcasts on wallet and transaction changes" do
    Wallets.subscribe()
    wallet = wallet!()
    assert_receive {:wallet_changed, :created, _}

    {:ok, _} =
      Wallets.add_transaction(wallet, %{
        kind: "income",
        amount_cents: 1_000,
        occurred_on: ~D[2026-06-01]
      })

    assert_receive {:wallet_transaction, :created, _}
    assert_receive {:wallet_changed, :updated, _}
  end
end
