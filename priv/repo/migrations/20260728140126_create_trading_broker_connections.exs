defmodule BusterClaw.Repo.Migrations.CreateTradingBrokerConnections do
  use Ecto.Migration

  def change do
    create table(:trading_broker_connections) do
      add :provider, :string, null: false
      add :client_id, :string
      add :access_token, :binary
      add :refresh_token, :binary
      add :access_token_expires_at, :utc_datetime_usec
      add :scope, :string
      add :status, :string, null: false, default: "disconnected"
      add :connected_at, :utc_datetime_usec
      add :last_checked_at, :utc_datetime_usec
      add :last_error, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:trading_broker_connections, [:provider])

    create table(:trading_broker_accounts) do
      add :connection_id,
          references(:trading_broker_connections, on_delete: :delete_all),
          null: false

      add :account_key, :string, null: false
      add :broker_account_id, :binary, null: false
      add :label, :string, null: false
      add :agentic, :boolean, null: false, default: false
      add :can_trade, :boolean, null: false, default: false
      add :metadata, :map, null: false, default: %{}
      add :broker_timestamp, :utc_datetime_usec
      add :fetched_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:trading_broker_accounts, [:connection_id, :account_key])
    create index(:trading_broker_accounts, [:agentic, :can_trade])
  end
end
