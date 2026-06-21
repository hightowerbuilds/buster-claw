defmodule BusterClaw.Repo.Migrations.CreateWallets do
  use Ecto.Migration

  def change do
    create table(:wallets) do
      add :name, :string, null: false
      add :type, :string, null: false
      add :currency, :string, null: false, default: "USD"
      add :balance_cents, :integer, null: false, default: 0
      add :archived, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:wallets, [:type])
  end
end
