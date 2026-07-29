defmodule BusterClaw.Repo.Migrations.AddDockedToConversations do
  use Ecto.Migration

  # Whether a Trading conversation is docked into the sub-tab system (filling its
  # tab) or floating over the panel. Persisted rather than session state because
  # docking is a layout decision the operator makes once, not something they
  # should have to redo on every reload — unlike which windows happen to be open.
  #
  # Home conversations are never docked and never read this.
  def change do
    alter table(:agent_conversations) do
      add :docked, :boolean, null: false, default: false
    end
  end
end
