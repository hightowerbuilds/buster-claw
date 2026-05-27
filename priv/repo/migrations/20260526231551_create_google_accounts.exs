defmodule BusterClaw.Repo.Migrations.CreateGoogleAccounts do
  use Ecto.Migration

  def change do
    create table(:google_accounts) do
      add :email, :string, null: false
      add :client_id, :text, null: false
      add :client_secret_enc, :binary
      add :refresh_token_enc, :binary
      add :access_token_enc, :binary
      add :access_token_expires_at, :utc_datetime
      add :scopes, :text
      add :default_query, :text
      add :last_synced_at, :utc_datetime
      add :last_seen_history_id, :string
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:google_accounts, [:email])
    create index(:google_accounts, [:enabled])
    create index(:google_accounts, [:last_synced_at])
  end
end
