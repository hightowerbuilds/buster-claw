defmodule BusterClaw.Repo.Migrations.RetypeResearchConversationsToChartbuild do
  @moduledoc """
  The Research chat is gone; Chart Build inherited its job (see
  daily-growth/roadmaps/CHART_BUILD_WEB_DATA_ROADMAP.md Phase 0).

  This runs BEFORE `"research"` leaves `Conversation.@kinds`, which is the whole
  point of it existing. `kind` is validated by inclusion, so dropping the value
  without retyping the rows would strand every Research conversation an operator
  had open: `Conversations.list_kinds/1` stops returning them (invisible tab,
  transcript orphaned but not deleted), and any later `set_kind/2` on one fails
  changeset validation for a value it never chose.

  Retyping rather than archiving is deliberate — the transcripts are the point.
  Same reasoning as the `"trading"` conv_id adoption in `Conversations.ensure/2`:
  when a surface's job moves, its history moves with it.
  """
  use Ecto.Migration

  def up do
    execute "UPDATE agent_conversations SET kind = 'chartbuild' WHERE kind = 'research'"
  end

  # Irreversible on purpose. Rolling back cannot tell a conversation that WAS
  # research from one the operator created as chartbuild, and guessing would
  # retype real Chart Build tabs into a kind the code no longer serves. The
  # forward migration loses no data — only a label — so there is nothing to
  # restore.
  def down, do: :ok
end
