defmodule BusterClaw.Repo.Migrations.AddDispatchStrategy do
  use Ecto.Migration

  # A queued item's execution strategy. "single" (default) is the existing
  # agent-pulls-queue path; "swarm" opts the item into the Phase 4 coordinator
  # (LLM decomposes it into a parallel Swarm plan).
  def change do
    alter table(:dispatch_items) do
      add :strategy, :string, null: false, default: "single"
    end
  end
end
