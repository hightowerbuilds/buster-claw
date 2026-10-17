defmodule BusterClaw.Repo.Migrations.DropIntegrations do
  @moduledoc """
  The Integrations feature — GitHub activity polling into Library snapshots,
  with a secret-verified webhook — left on 10-17. It had never been used, and
  the direction it was built for is served by MCP now. `integration_runs` and
  `integrations` held its rows; nothing reads or writes them any more.

  Forward only: `down` recreates nothing, because there is no code left to fill
  the tables, and a recreated empty table would only look like a feature. The
  Library documents a poll once wrote stay where they are.
  """
  use Ecto.Migration

  def up do
    drop_if_exists table(:integration_runs)
    drop_if_exists table(:integrations)
  end

  def down, do: :ok
end
