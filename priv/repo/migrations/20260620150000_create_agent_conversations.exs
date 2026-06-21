defmodule BusterClaw.Repo.Migrations.CreateAgentConversations do
  use Ecto.Migration

  def change do
    create table(:agent_conversations, primary_key: false) do
      add :id, :string, primary_key: true
      add :title, :string, null: false
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Open conversations (archived_at IS NULL), ordered for the tab strip.
    create index(:agent_conversations, [:archived_at, :inserted_at])
  end
end
