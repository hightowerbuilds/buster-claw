defmodule BusterClaw.Repo.Migrations.CreateRealizedPnlPoints do
  use Ecto.Migration

  # The backfill (PORTFOLIO_HISTORY_ROADMAP Phase 3).
  #
  # Our own ledger starts the day it starts, which would leave the chart empty
  # for weeks. `get_realized_pnl` with span "all" is the one piece of real
  # history Robinhood will hand over — probed 07-27, it returns MONTHLY buckets
  # going back to 2024.
  #
  # It measures something narrower than the recorded series: realized gains from
  # closed trades only, with nothing for positions still held. That is why the
  # chart draws it dashed and labels the seam — the change at the seam is one of
  # completeness, not of units.
  #
  # `realized_cents` is SIGNED: a losing month is a real and important number
  # (the probe found a -$1,076 month), so this column must never inherit the
  # non-negative discipline that guards account values.
  def change do
    create table(:realized_pnl_points) do
      add :account_key, :string, null: false
      # The bucket's start date. Monthly at span "all", but stored as whatever
      # the tool reports rather than assumed — the granularity is the API's to
      # choose, and pretending it is daily would fabricate resolution.
      add :bucket_on, :date, null: false
      add :realized_cents, :integer, null: false, default: 0
      # 0 means the tool reported no closing trades in the window (it sends a
      # null realized figure for those). Zero trades and a genuine zero-dollar
      # result are different facts, and this is what tells them apart.
      add :trades, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:realized_pnl_points, [:account_key, :bucket_on])
  end
end
