defmodule BusterClaw.Repo.Migrations.AddCalendarSyncTokensToGoogleAccounts do
  use Ecto.Migration

  def change do
    alter table(:google_accounts) do
      add :calendar_sync_tokens, :map, null: false, default: %{}
    end
  end
end
