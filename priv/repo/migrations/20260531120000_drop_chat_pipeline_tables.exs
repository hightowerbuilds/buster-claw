defmodule BusterClaw.Repo.Migrations.DropChatPipelineTables do
  use Ecto.Migration

  # Removes the schema for the cut chat/provider + ingest→analyze→report pipeline.
  # Kept: documents (workspace markdown index, decoupled from sources) and
  # delivery_attempts/delivery_destinations (decoupled from reports).

  def up do
    drop_if_exists index(:delivery_attempts, [:report_id])

    alter table(:delivery_attempts) do
      remove :report_id
    end

    drop_if_exists index(:documents, [:source_id])

    alter table(:documents) do
      remove :source_id
    end

    drop_if_exists table(:analysis_jobs)
    drop_if_exists table(:reports)
    drop_if_exists table(:sources)
    drop_if_exists table(:providers)
  end

  def down do
    create table(:sources) do
      add :url, :text, null: false
      add :type, :string, null: false
      add :name, :string
      add :tags, :map, null: false, default: %{}
      add :browser_engine, :string
      add :cookies, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sources, [:url])
    create index(:sources, [:type])
    create index(:sources, [:enabled])

    create table(:providers) do
      add :name, :string, null: false
      add :type, :string, null: false
      add :base_url, :text
      add :api_key, :text
      add :model, :string, null: false
      add :active, :boolean, null: false, default: false
      add :priority, :integer, null: false, default: 100

      timestamps(type: :utc_datetime)
    end

    create unique_index(:providers, [:name])
    create index(:providers, [:type])
    create index(:providers, [:active])

    alter table(:documents) do
      add :source_id, references(:sources, on_delete: :nilify_all)
    end

    create index(:documents, [:source_id])

    create table(:reports) do
      add :document_id, references(:documents, on_delete: :nilify_all)
      add :provider_id, references(:providers, on_delete: :nilify_all)
      add :filename, :string, null: false
      add :artifact_path, :text, null: false
      add :source_file, :string
      add :source_url, :text
      add :model, :string
      add :tags, :map, null: false, default: %{}
      add :generated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:reports, [:artifact_path])
    create index(:reports, [:document_id])
    create index(:reports, [:provider_id])
    create index(:reports, [:source_file])
    create index(:reports, [:generated_at])

    create table(:analysis_jobs) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :report_id, references(:reports, on_delete: :nilify_all)
      add :provider_id, references(:providers, on_delete: :nilify_all)
      add :status, :string, null: false, default: "queued"
      add :progress, :integer, null: false, default: 0
      add :model, :string
      add :error, :text
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:analysis_jobs, [:document_id])
    create index(:analysis_jobs, [:report_id])
    create index(:analysis_jobs, [:provider_id])
    create index(:analysis_jobs, [:status])

    alter table(:delivery_attempts) do
      add :report_id, references(:reports, on_delete: :nilify_all)
    end

    create index(:delivery_attempts, [:report_id])
  end
end
