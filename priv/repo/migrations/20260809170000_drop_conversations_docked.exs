defmodule BusterClaw.Repo.Migrations.DropConversationsDocked do
  use Ecto.Migration

  @moduledoc """
  `agent_conversations.docked` recorded whether a *Trading* conversation was
  docked into that page's sub-tab system (see
  `20260728235000_add_docked_to_conversations`, which said so and added that
  "Home conversations are never docked and never read this"). Trading left whole
  on 08-08 (`drop_trading_stack`), taking the only surface that would have read
  the flag with it — and it never did read it: no query filtered on it, no
  template rendered it, nothing branched on it. `Conversations.set_docked/2` was
  its sole writer and had zero callers in `lib/`, `test/`, `assets/` or `priv/`,
  so every row has carried `docked: false` since the column was added. Removed
  with the writer and the schema field (DEAD_CODE_ROADMAP F1c).

  **The rollback here is real, not decorative.** `change/0` reverses into an
  `add :docked, :boolean, null: false, default: false` — the column's original
  definition, byte for byte — and that restores the full truth of the data
  because `false` is the only value any row ever held. There is nothing to lose,
  which is what separates this from `drop_trading_stack`, whose `down/0` has to
  raise because its tables held readings no rollback could rebuild.
  """

  def change do
    alter table(:agent_conversations) do
      remove :docked, :boolean, null: false, default: false
    end
  end
end
