defmodule BusterClaw.Repo.Migrations.CreateDispatchItems do
  use Ecto.Migration

  def change do
    create table(:dispatch_items) do
      add :source, :string, null: false
      add :source_account, :string
      add :sender, :string
      add :trusted_sender, :string
      add :trusted, :boolean, null: false, default: false
      add :auth_status, :string, null: false, default: "unverified"
      add :gmail_message_id, :string
      add :gmail_thread_id, :string
      add :subject, :string
      add :request_summary, :text
      add :request_body_excerpt, :text
      add :recommended_agent, :string
      add :recommended_role_key, :string
      add :risk, :string
      add :status, :string, null: false, default: "queued"
      add :shift_id, references(:shifts, on_delete: :nilify_all)
      add :shift_assignment_id, references(:shift_assignments, on_delete: :nilify_all)
      add :orchestrator_task_id, references(:orchestrator_tasks, on_delete: :nilify_all)
      add :dedupe_key, :string, null: false
      add :claimed_by, :string
      add :claimed_at, :utc_datetime
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      add :heartbeat_at, :utc_datetime
      add :outcome, :text
      add :notes, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:dispatch_items, [:dedupe_key])
    create index(:dispatch_items, [:status])
    create index(:dispatch_items, [:source])
    create index(:dispatch_items, [:gmail_message_id])
    create index(:dispatch_items, [:shift_id])
    create index(:dispatch_items, [:shift_assignment_id])
    create index(:dispatch_items, [:orchestrator_task_id])
    create index(:dispatch_items, [:recommended_role_key])
  end
end
