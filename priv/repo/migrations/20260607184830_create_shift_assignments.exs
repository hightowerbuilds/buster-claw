defmodule BusterClaw.Repo.Migrations.CreateShiftAssignments do
  use Ecto.Migration

  def change do
    create table(:shift_assignments) do
      add :shift_id, references(:shifts, on_delete: :delete_all), null: false
      add :role_key, :string, null: false
      add :agent_name, :string
      add :shell, :string
      add :status, :string, null: false, default: "active"
      add :started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime
      add :heartbeat_at, :utc_datetime
      add :purpose, :text
      add :dedupe_key, :string
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:shift_assignments, [:shift_id])
    create index(:shift_assignments, [:status])
    create index(:shift_assignments, [:role_key])
    create index(:shift_assignments, [:dedupe_key])
  end
end
