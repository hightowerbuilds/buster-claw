defmodule BusterClaw.Repo.Migrations.AddKindToConversations do
  use Ecto.Migration

  # Which surface a conversation's tab belongs to, and — on the Trading page —
  # what it is allowed to talk to. Every existing row is a Home chat, which is
  # exactly what the default backfills.
  #
  # The Trading page's conversation used to be DB-less on purpose: a row would
  # have made it appear in Home's chat strip, which it must not. `kind` is what
  # lets it have a row now — Home lists `home`, Trading lists the rest.
  def change do
    alter table(:agent_conversations) do
      add :kind, :string, null: false, default: "home"
    end

    create index(:agent_conversations, [:kind])
  end
end
