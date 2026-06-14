defmodule BusterClaw.Repo.Migrations.DropRetiredAutomationTables do
  use Ecto.Migration

  # Retired the Delivery, Hooks, Webhooks, Scheduler, and (DB-backed) Memory
  # features — unused in practice (only smoke-test rows). Integrations is kept.
  # Child tables (FKs) are dropped before their parents.
  def up do
    drop_if_exists table(:delivery_attempts)
    drop_if_exists table(:hook_runs)
    drop_if_exists table(:runtime_events)
    drop_if_exists table(:delivery_destinations)
    drop_if_exists table(:hooks)
    drop_if_exists table(:webhooks)
    drop_if_exists table(:scheduler_jobs)
    drop_if_exists table(:memories)
  end

  def down do
    raise Ecto.MigrationError,
      message: "drop_retired_automation_tables is irreversible (schemas were removed)"
  end
end
