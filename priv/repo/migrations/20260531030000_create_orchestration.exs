defmodule BusterClaw.Repo.Migrations.CreateOrchestration do
  use Ecto.Migration

  def change do
    create table(:shifts) do
      add :started_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false
      add :status, :string, null: false, default: "active"
      add :dispatched_count, :integer, null: false, default: 0
      add :done_count, :integer, null: false, default: 0
      add :failed_count, :integer, null: false, default: 0
      add :stopped_reason, :string

      timestamps(type: :utc_datetime)
    end

    create index(:shifts, [:status])

    create table(:orchestrator_tasks) do
      add :name, :string, null: false
      add :type, :string, null: false, default: "agent"
      add :engine, :string
      add :command, :string
      add :prompt, :text
      add :params, :map, null: false, default: %{}
      add :cron, :string
      add :due_at, :utc_datetime
      add :next_run_at, :utc_datetime
      add :last_run_at, :utc_datetime
      add :enabled, :boolean, null: false, default: true
      add :state, :string, null: false, default: "pending"
      add :lease_owner, :string
      add :lease_expires_at, :utc_datetime
      add :attempts, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 3
      add :result_path, :string
      add :error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:orchestrator_tasks, [:state])
    create index(:orchestrator_tasks, [:next_run_at])
    create index(:orchestrator_tasks, [:due_at])

    create table(:agent_runs) do
      add :task_id, references(:orchestrator_tasks, on_delete: :nilify_all)
      add :engine, :string, null: false
      add :os_pid, :integer
      add :status, :string, null: false, default: "running"
      add :started_at, :utc_datetime
      add :last_heartbeat_at, :utc_datetime
      add :finished_at, :utc_datetime
      add :exit_code, :integer
      add :output_path, :string
      add :error, :string

      timestamps(type: :utc_datetime)
    end

    create index(:agent_runs, [:task_id])
    create index(:agent_runs, [:status])
  end
end
