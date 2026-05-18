defmodule BusterClaw.Repo.Migrations.CreateIntegrations do
  use Ecto.Migration

  def change do
    create table(:integrations) do
      add :name, :string, null: false
      add :service_type, :string, null: false
      add :base_url, :text
      add :token, :text
      add :webhook_secret, :text
      add :config, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true
      add :polling_interval_minutes, :integer, null: false, default: 60
      add :last_run_at, :utc_datetime
      add :last_status, :string, null: false, default: "never_run"
      add :last_error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:integrations, [:name])
    create index(:integrations, [:service_type])
    create index(:integrations, [:enabled])
    create index(:integrations, [:last_status])

    create table(:integration_runs) do
      add :integration_id, references(:integrations, on_delete: :delete_all), null: false
      add :document_id, references(:documents, on_delete: :nilify_all)
      add :trigger, :string, null: false
      add :status, :string, null: false
      add :records_fetched, :integer, null: false, default: 0
      add :error, :text
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:integration_runs, [:integration_id])
    create index(:integration_runs, [:document_id])
    create index(:integration_runs, [:trigger])
    create index(:integration_runs, [:status])
    create index(:integration_runs, [:started_at])
  end
end
