defmodule BusterClaw.Repo.Migrations.DropIntegrationPollingInterval do
  use Ecto.Migration

  @moduledoc """
  `polling_interval_minutes` was persisted, validated, shown in Settings, and
  read by nothing — there is no integration poller; polls are on demand only.
  A setting that knowingly does nothing is worse than an absent setting
  (CODE_QUALITY_REFACTOR_ROADMAP Part II, removed 08-02). Forward migration on
  purpose: applied history is never edited.
  """

  def change do
    alter table(:integrations) do
      remove :polling_interval_minutes, :integer, default: 60
    end
  end
end
