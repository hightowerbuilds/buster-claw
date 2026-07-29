defmodule BusterClaw.Repo.Migrations.CreateTradingOrderWorkflow do
  use Ecto.Migration

  def change do
    create table(:trading_order_intents) do
      add :public_id, :string, null: false
      add :status, :string, null: false
      add :account_id, :string, null: false
      add :account_label, :string
      add :symbol, :string, null: false
      add :side, :string, null: false
      add :quantity_micros, :integer
      add :notional_cents, :integer
      add :order_type, :string, null: false
      add :limit_price_cents, :integer
      add :time_in_force, :string, null: false

      add :quote_cents, :integer
      add :buying_power_cents, :integer
      add :estimated_notional_cents, :integer
      add :concentration_bps, :integer
      add :broker_preview, :map
      add :broker_preview_id, :string
      add :broker_timestamp, :utc_datetime_usec

      add :preview_payload, :map
      add :preview_digest, :string
      add :confirmation_digest, :string
      add :confirmation_expires_at, :utc_datetime_usec
      add :confirmed_at, :utc_datetime_usec

      add :client_order_id, :string, null: false
      add :broker_order_id, :string
      add :broker_status, :string
      add :broker_response, :map
      add :submitted_at, :utc_datetime_usec
      add :last_reconciled_at, :utc_datetime_usec
      add :failure_reason, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:trading_order_intents, [:public_id])
    create unique_index(:trading_order_intents, [:client_order_id])
    create index(:trading_order_intents, [:status])
    create index(:trading_order_intents, [:inserted_at])

    create table(:trading_order_events) do
      add :order_intent_id,
          references(:trading_order_intents, on_delete: :restrict),
          null: false

      add :event_type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:trading_order_events, [:order_intent_id, :occurred_at])
  end
end
