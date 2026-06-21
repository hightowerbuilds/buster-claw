defmodule BusterClaw.Repo.Migrations.CreateSkillSuggestions do
  use Ecto.Migration

  @moduledoc """
  Self-improvement (Phase 3): the Analyzer files proposed composition skills here.
  A suggestion is NEVER auto-enabled — an operator approves it, which writes the
  enabled `skills/*.md`. `steps_json` is the proposed ordered command list (JSON),
  matching the same JSON-in-text round-trip the Skills loader uses.
  """

  def change do
    create table(:skill_suggestions) do
      # The sequence's stable identity (commands joined), used to dedupe repeats.
      add :signature, :string, null: false
      add :name, :string, null: false
      add :description, :string
      add :steps_json, :text, null: false
      add :occurrences, :integer, null: false, default: 1
      add :status, :string, null: false, default: "pending"
      add :caller, :string
      add :last_seen, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:skill_suggestions, [:status])
    # One open (pending) suggestion per distinct sequence; resolved ones (approved/
    # rejected) are kept for history and don't block a fresh proposal later.
    create unique_index(:skill_suggestions, [:signature],
             where: "status = 'pending'",
             name: :skill_suggestions_pending_signature
           )
  end
end
