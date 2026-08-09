defmodule BusterClaw.Repo.Migrations.DropMcpServers do
  @moduledoc """
  Drops `mcp_servers`, the table that backed the MCP endpoint deleted in the
  pull-queue cut.

  Created by `20260507150000_create_initial_rewrite_tables.exs` and never
  dropped, it outlived its endpoint by three months: no Ecto schema, no query,
  no reference anywhere in `lib/`. Nothing has ever written a row to it since
  the endpoint went, and nothing could.

  The scoped `:mcp` API token tier in `BusterClaw.ApiToken` is a DIFFERENT
  thing and is still live. This migration does not touch it.

  Unlike `drop_trading_stack`, `down/0` here is a real rollback rather than a
  raise: the table has no writer, so recreating it empty restores exactly what
  was dropped. Nothing is lost that a rollback would have to pretend to give
  back.
  """
  use Ecto.Migration

  def up do
    # SQLite drops a table's indexes with it, so the three indexes created
    # alongside this table need no separate statement.
    drop_if_exists(table(:mcp_servers))
  end

  def down do
    create table(:mcp_servers) do
      add :name, :string, null: false
      add :command, :text, null: false
      add :args, :map, null: false, default: %{}
      add :env, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true
      add :last_status, :string
      add :last_error, :text
      add :last_connected_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:mcp_servers, [:name])
    create index(:mcp_servers, [:enabled])
    create index(:mcp_servers, [:last_status])
  end
end
