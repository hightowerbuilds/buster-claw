defmodule BusterClaw.Repo.Migrations.CreateInitialRewriteTables do
  use Ecto.Migration

  def change do
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

    create table(:mcp_servers) do
      add :name, :string, null: false
      add :command, :text, null: false
      add :args, :map, null: false, default: %{}
      add :env, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true
      add :last_status, :string
      add :last_error, :text
      add :last_connected_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:mcp_servers, [:name])
    create index(:mcp_servers, [:enabled])
    create index(:mcp_servers, [:last_status])

    create table(:webhooks) do
      add :name, :string, null: false
      add :secret, :text
      add :action, :string, null: false
      add :custom_cmd, :text
      add :deliver_to, :string
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:webhooks, [:name])
    create index(:webhooks, [:action])
    create index(:webhooks, [:enabled])

    create table(:hooks) do
      add :name, :string, null: false
      add :event, :string, null: false
      add :type, :string, null: false
      add :target, :text, null: false
      add :async, :boolean, null: false, default: true
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:hooks, [:name, :event])
    create index(:hooks, [:event])
    create index(:hooks, [:enabled])

    create table(:delivery_destinations) do
      add :name, :string, null: false
      add :type, :string, null: false
      add :url, :text
      add :token, :text
      add :chat_id, :string
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:delivery_destinations, [:name])
    create index(:delivery_destinations, [:type])
    create index(:delivery_destinations, [:enabled])

    create table(:scheduler_jobs) do
      add :job_id, :string, null: false
      add :type, :string, null: false
      add :cron, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :custom_cmd, :text
      add :deliver_to, :string
      add :last_run_at, :utc_datetime
      add :next_run_at, :utc_datetime
      add :last_error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:scheduler_jobs, [:job_id])
    create index(:scheduler_jobs, [:type])
    create index(:scheduler_jobs, [:enabled])
    create index(:scheduler_jobs, [:next_run_at])

    create table(:calendar_events) do
      add :event_id, :string, null: false
      add :date, :date, null: false
      add :title, :string, null: false
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:calendar_events, [:event_id])
    create index(:calendar_events, [:date])

    create table(:memories) do
      add :created_at, :utc_datetime, null: false
      add :text, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:memories, [:created_at])

    create table(:documents) do
      add :source_id, references(:sources, on_delete: :nilify_all)
      add :filename, :string, null: false
      add :artifact_path, :text, null: false
      add :date, :date
      add :source_url, :text
      add :name, :string
      add :tags, :map, null: false, default: %{}
      add :content_hash, :string
      add :status, :string, null: false, default: "fetched"
      add :excerpt, :text
      add :fetched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:documents, [:artifact_path])
    create index(:documents, [:source_id])
    create index(:documents, [:source_url])
    create index(:documents, [:content_hash])
    create index(:documents, [:status])
    create index(:documents, [:date])

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

    create table(:delivery_attempts) do
      add :delivery_destination_id, references(:delivery_destinations, on_delete: :nilify_all)
      add :report_id, references(:reports, on_delete: :nilify_all)
      add :title, :string, null: false
      add :status, :string, null: false, default: "queued"
      add :error, :text
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:delivery_attempts, [:delivery_destination_id])
    create index(:delivery_attempts, [:report_id])
    create index(:delivery_attempts, [:status])

    create table(:hook_runs) do
      add :hook_id, references(:hooks, on_delete: :nilify_all)
      add :event, :string, null: false
      add :type, :string, null: false
      add :started_at, :utc_datetime, null: false
      add :duration_ms, :integer
      add :success, :boolean, null: false, default: false
      add :error, :text
      add :stdout, :text
      add :stderr, :text
      add :status_code, :integer
      add :payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:hook_runs, [:hook_id])
    create index(:hook_runs, [:event])
    create index(:hook_runs, [:success])
    create index(:hook_runs, [:started_at])

    create table(:runtime_events) do
      add :kind, :string, null: false
      add :message, :text, null: false
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:runtime_events, [:kind])
    create index(:runtime_events, [:occurred_at])
  end
end
