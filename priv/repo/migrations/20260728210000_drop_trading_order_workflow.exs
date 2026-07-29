defmodule BusterClaw.Repo.Migrations.DropTradingOrderWorkflow do
  use Ecto.Migration

  # The deterministic order lane (its own broker connection, OAuth tokens, and a
  # draft→review→confirm intent chain) is gone; trade creation is a confirm step
  # inside the trading chat instead. These tables only ever existed on a machine
  # that ran the two create migrations before they were reverted, so every drop
  # is guarded — on a fresh database this migration is a no-op.
  def up do
    drop_if_exists table(:trading_order_events)
    drop_if_exists table(:trading_order_intents)
    drop_if_exists table(:trading_broker_accounts)
    drop_if_exists table(:trading_broker_connections)
  end

  # Irreversible on purpose: the schemas these tables backed no longer exist, so
  # there is nothing for a rollback to recreate them from.
  def down, do: :ok
end
