defmodule BusterClaw.Repo.Migrations.CreatePositionCosts do
  use Ecto.Migration

  # Cost basis per (account, symbol), aggregated from get_equity_tax_lots
  # (TRADING_TAB_ROADMAP Phase 3). This is what turns "GOOGL is worth $81" into
  # "you're up $14.20 on GOOGL" — value minus what was actually paid.
  #
  # cost_basis_cents is NULLABLE, and the null is load-bearing: the tax-lot tool
  # can fail for one symbol while the position itself is real. A row with a null
  # basis renders "cost basis unavailable" — never $0, which would claim the
  # shares were free and inflate the gain by the whole purchase price.
  def change do
    create table(:position_costs) do
      add :account_key, :string, null: false
      add :symbol, :string, null: false
      # Fractional shares; display only — never money math on this column.
      add :quantity, :float, null: false
      add :lots, :integer, null: false, default: 0
      add :cost_basis_cents, :integer
      add :as_of, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:position_costs, [:account_key, :symbol])
  end
end
