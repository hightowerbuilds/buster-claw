defmodule BusterClaw.Repo.Migrations.CreateWalletTransactions do
  use Ecto.Migration

  def change do
    create table(:wallet_transactions) do
      add :wallet_id, references(:wallets, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :category, :string
      add :description, :string
      add :occurred_on, :date, null: false
      add :source, :string, null: false, default: "manual"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:wallet_transactions, [:wallet_id, :occurred_on])
  end
end
