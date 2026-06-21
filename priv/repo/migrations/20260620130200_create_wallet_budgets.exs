defmodule BusterClaw.Repo.Migrations.CreateWalletBudgets do
  use Ecto.Migration

  def change do
    create table(:wallet_budgets) do
      add :wallet_id, references(:wallets, on_delete: :delete_all), null: false
      add :month, :string, null: false
      add :income_target_cents, :integer, null: false, default: 0
      add :expense_target_cents, :integer, null: false, default: 0
      add :savings_target_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:wallet_budgets, [:wallet_id, :month])
  end
end
