defmodule BusterClaw.Repo.Migrations.CreateWalletFeeds do
  use Ecto.Migration

  def change do
    create table(:wallet_feeds) do
      add :wallet_id, references(:wallets, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :polling_interval_minutes, :integer, null: false, default: 60
      add :config, :map, null: false, default: %{}
      add :last_run_at, :utc_datetime
      add :last_status, :string, null: false, default: "never_run"
      add :last_error, :string
      add :last_value, :string
      add :last_content_hash, :string

      timestamps(type: :utc_datetime)
    end

    create index(:wallet_feeds, [:wallet_id])
    create index(:wallet_feeds, [:enabled])
  end
end
