defmodule BusterClaw.Repo.Migrations.RemoveWalletTables do
  use Ecto.Migration

  def change do
    # Child tables must go first because they reference wallets.
    drop table(:wallet_feeds)
    drop table(:wallet_budgets)
    drop table(:wallet_transactions)
    drop table(:wallets)
  end
end
