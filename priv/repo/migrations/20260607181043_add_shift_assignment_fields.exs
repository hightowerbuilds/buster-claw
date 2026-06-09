defmodule BusterClaw.Repo.Migrations.AddShiftAssignmentFields do
  use Ecto.Migration

  def change do
    alter table(:shifts) do
      add :job_key, :string, null: false, default: "lookout"
      add :job_name, :string, null: false, default: "Lookout"
      add :job_description, :text
      add :agent_name, :string
      add :shell, :string
      add :duration_hours, :integer, null: false, default: 12
    end

    create index(:shifts, [:job_key])
  end
end
