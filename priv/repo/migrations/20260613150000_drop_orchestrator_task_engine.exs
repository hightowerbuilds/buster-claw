defmodule BusterClaw.Repo.Migrations.DropOrchestratorTaskEngine do
  use Ecto.Migration

  def up do
    drop_if_exists table(:agent_runs)
    drop_if_exists table(:orchestrator_tasks)

    drop_if_exists index(:dispatch_items, [:orchestrator_task_id])

    alter table(:dispatch_items) do
      remove :orchestrator_task_id
    end
  end

  def down do
    raise Ecto.MigrationError,
      message: "drop_orchestrator_task_engine is forward-only and cannot be reversed"
  end
end
