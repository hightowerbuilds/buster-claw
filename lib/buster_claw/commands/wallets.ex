defmodule BusterClaw.Commands.Wallets do
  @moduledoc "Wallet commands beyond the generated CRUD: ledger transactions, budgets, feeds, polling. Delegated to from `BusterClaw.Commands`."

  import BusterClaw.Commands.Helpers

  alias BusterClaw.Wallets

  def wallet_list_transactions(%{"wallet_id" => wallet_id}) do
    with_resource(Wallets, :get_wallet!, wallet_id, fn wallet ->
      {:ok, Wallets.list_transactions(wallet)}
    end)
  end

  def wallet_add_transaction(%{"wallet_id" => wallet_id} = args) do
    with_resource(Wallets, :get_wallet!, wallet_id, fn wallet ->
      Wallets.add_transaction(wallet, Map.delete(args, "wallet_id"))
    end)
  end

  def wallet_set_budget(%{"wallet_id" => wallet_id} = args) do
    with_resource(Wallets, :get_wallet!, wallet_id, fn wallet ->
      Wallets.upsert_budget(wallet, Map.delete(args, "wallet_id"))
    end)
  end

  def wallet_budget_summary(%{"wallet_id" => wallet_id, "month" => month}) do
    with_resource(Wallets, :get_wallet!, wallet_id, fn wallet ->
      {:ok, Wallets.budget_summary(wallet, month)}
    end)
  end

  def wallet_feed_list(%{"wallet_id" => wallet_id}) do
    with_resource(Wallets, :get_wallet!, wallet_id, fn wallet ->
      {:ok, Wallets.list_feeds(wallet)}
    end)
  end

  def wallet_feed_create(%{"wallet_id" => wallet_id} = args) do
    with_resource(Wallets, :get_wallet!, wallet_id, fn wallet ->
      Wallets.create_feed(wallet, Map.delete(args, "wallet_id"))
    end)
  end

  def wallet_feed_update(%{"id" => id} = args) do
    with_resource(Wallets, :get_feed!, id, fn feed ->
      Wallets.update_feed(feed, Map.delete(args, "id"))
    end)
  end

  def wallet_feed_delete(%{"id" => id}) do
    with_resource(Wallets, :get_feed!, id, fn feed ->
      Wallets.delete_feed(feed)
    end)
  end

  def wallet_poll(%{"id" => id}) do
    with_resource(Wallets, :get_wallet!, id, fn wallet ->
      {:ok, %{results: length(Wallets.poll_wallet_feeds(wallet))}}
    end)
  end
end
