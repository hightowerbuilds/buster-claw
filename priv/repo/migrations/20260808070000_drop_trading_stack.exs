defmodule BusterClaw.Repo.Migrations.DropTradingStack do
  @moduledoc """
  Removes every trace of the trading stack, deleted whole on 2026-08-08.

  Trading, Portfolio, MarketData, Watchlist and Chart Build left together
  because they were one dependency chain, not five features: the portfolio
  ledger and the bar cache had no writer other than the broker prompts in
  `Trading`, and Chart Build had no LiveView of its own.

  **This migration is deliberately irreversible.** `down/0` raises rather than
  pretending: the recorded portfolio history cannot be rebuilt, because Robinhood
  publishes no historical account values — that fact is the reason the readings
  were being filed daily in the first place. Restoring the schema would give back
  empty tables and call it a rollback. Operator decision, 2026-08-08, taken with
  that stated.
  """
  use Ecto.Migration

  # Rows the app can no longer render: the Trading page's tab kinds. `home` is
  # the only kind the schema still admits, so leaving these would strand them
  # behind a `validate_inclusion` that no longer lists their value — the same
  # ordering trap the 08-03 research retype had to step around, which is why
  # this runs before that list ships narrowed.
  @dead_kinds ~w(chat robinhood chartbuild)

  # Settings rows the stack owned. Keyed individually rather than by prefix so
  # this reads as an inventory: anything not named here survives.
  @dead_settings [
    "trading_account_snapshot",
    "portfolio_excluded_accounts",
    "portfolio_costs_refreshed_at",
    "market_data_attempted_on",
    "market_quotes_snapshot",
    "benchmark_backfill_attempted_on",
    "benchmark_backfill_outcomes",
    "watchlists",
    "extension:trading-robinhood"
  ]

  def up do
    kinds = Enum.map_join(@dead_kinds, ",", &"'#{&1}'")

    # Transcripts first: `agent_chat_messages` references conversations by
    # `conv_id` with no foreign key, so deleting the parents first would orphan
    # every message rather than remove it.
    execute("""
    DELETE FROM agent_chat_messages
    WHERE conv_id IN (SELECT id FROM agent_conversations WHERE kind IN (#{kinds}))
    """)

    execute("DELETE FROM agent_conversations WHERE kind IN (#{kinds})")

    for key <- @dead_settings do
      execute("DELETE FROM app_settings WHERE key = '#{key}'")
    end

    drop_if_exists(table(:portfolio_snapshots))
    drop_if_exists(table(:portfolio_flows))
    drop_if_exists(table(:realized_pnl_points))
    drop_if_exists(table(:position_costs))
    drop_if_exists(table(:symbol_bars))
  end

  def down do
    raise Ecto.MigrationError,
      message: """
      drop_trading_stack cannot be rolled back.

      The tables can be recreated by earlier migrations, but their contents
      cannot: the portfolio readings were the only record of daily account
      values, and the broker publishes no history to refetch them from. A
      rollback that returned empty tables would look like a restore and be a
      loss. Restore from a database backup instead.
      """
  end
end
