defmodule BusterClaw.Repo.Migrations.CreatePortfolioSnapshots do
  use Ecto.Migration

  # The portfolio ledger (PORTFOLIO_HISTORY_ROADMAP Phase 0).
  #
  # Robinhood exposes no portfolio-value history — probed the full tool surface
  # 07-27 — so the daily series is ours to keep or lose. Nothing recovers a day
  # we failed to record, which makes this table load-bearing in a way the chart
  # it feeds is not.
  #
  # One row per account per market day. Money is integer cents (the
  # wallet_transactions precedent): the values arrive as floats from a model
  # reading a tool result, and a float ledger accumulates rounding drift the
  # chart would render as movement that never happened.
  def change do
    create table(:portfolio_snapshots) do
      # The last four digits of the account number — the same key stage 2
      # already matches accounts on. Never the full number: it isn't needed to
      # tell accounts apart, and it would persist here in cleartext.
      add :account_key, :string, null: false
      # Denormalized on purpose. A renamed account must not rewrite the label on
      # a year of history that was recorded under the old name.
      add :label, :string, null: false
      # The market day in America/New_York, matching get_realized_pnl's default
      # bucket boundary so the backfill and the recordings agree on "a day".
      add :captured_on, :date, null: false
      add :value_cents, :integer, null: false
      add :cash_cents, :integer
      add :buying_power_cents, :integer
      add :source, :string, null: false, default: "tab_open"

      timestamps(type: :utc_datetime)
    end

    # One reading per account per day; a later reading that day overwrites it.
    # This is what makes recording idempotent — opening the tab six times in an
    # afternoon must not leave six points on the chart.
    create unique_index(:portfolio_snapshots, [:account_key, :captured_on])

    # The chart's hot query: a date range, oldest first, across all accounts.
    create index(:portfolio_snapshots, [:captured_on])
  end
end
