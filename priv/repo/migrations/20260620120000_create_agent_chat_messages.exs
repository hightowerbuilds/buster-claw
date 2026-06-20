defmodule BusterClaw.Repo.Migrations.CreateAgentChatMessages do
  use Ecto.Migration

  def change do
    create table(:agent_chat_messages) do
      add :conv_id, :string, null: false
      add :role, :string, null: false
      add :content, :text, null: false
      add :session_id, :string
      add :cost_usd, :float
      add :num_turns, :integer

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:agent_chat_messages, [:conv_id, :inserted_at])
  end
end
