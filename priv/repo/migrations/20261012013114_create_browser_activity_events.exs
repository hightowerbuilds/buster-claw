defmodule BusterClaw.Repo.Migrations.CreateBrowserActivityEvents do
  use Ecto.Migration

  def change do
    create table(:browser_activity_events) do
      add :source, :string, null: false
      add :run_id, :string
      add :action, :string, null: false
      add :outcome, :string, null: false
      add :url, :string
      add :duration_ms, :integer
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:browser_activity_events, [:source, :id])
    create index(:browser_activity_events, [:run_id, :id])
  end
end
