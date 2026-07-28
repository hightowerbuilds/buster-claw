defmodule BusterClaw.Repo.Migrations.CreateSymbolBars do
  use Ecto.Migration

  # The price-history cache (TRADING_TAB_ROADMAP Phase 1).
  #
  # A cache of the API's truth, not a ledger of ours: unlike portfolio_snapshots,
  # nothing here is irreplaceable — a lost row is one `get_equity_historicals`
  # call away. What the table buys is that sparklines and day-change figures
  # render from SQLite with no agent run on tab open.
  #
  # Two tiers write here (see the roadmap's payload constraint):
  #   closes tier — batched daily closes for every held symbol; OHLC/volume null
  #   chart tier  — full OHLCV for one symbol on demand (Phase 4), upserting
  #                 over the closes-tier row for the same day
  def change do
    create table(:symbol_bars) do
      add :symbol, :string, null: false
      add :bar_on, :date, null: false
      add :close_cents, :integer, null: false
      add :open_cents, :integer
      add :high_cents, :integer
      add :low_cents, :integer
      add :volume, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:symbol_bars, [:symbol, :bar_on])
  end
end
