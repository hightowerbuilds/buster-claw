defmodule BusterClaw.Repo.Migrations.CreatePortfolioFlows do
  use Ecto.Migration

  # Deposits and withdrawals (PORTFOLIO_HISTORY_ROADMAP Phase 2).
  #
  # The Robinhood MCP surface has no transfers tool — probed 07-27 — so a cash
  # increase is equally explainable by a deposit, a sale, or a dividend. Guessing
  # would mean the app inventing claims about the user's money, so flows are
  # entered by hand and stored here. Gain is then computed AROUND them:
  # moving money in is not performance.
  #
  # `kind` carries three states, and the third is the load-bearing one:
  #
  #   deposit / withdrawal — a real transfer of `amount_cents`
  #   not_a_transfer       — reviewed, and it was genuine market movement
  #
  # Without `not_a_transfer` the anomaly prompt has no way to be answered "no"
  # and would nag about the same day forever. It is a zero-amount row on purpose:
  # the day has been accounted for, and the gain math treats it as untouched.
  def change do
    create table(:portfolio_flows) do
      add :account_key, :string, null: false
      add :occurred_on, :date, null: false
      # Signed: positive is money in, negative is money out, zero is
      # not_a_transfer. Integer cents, like every other amount in the ledger.
      add :amount_cents, :integer, null: false, default: 0
      add :kind, :string, null: false
      add :note, :string
      add :source, :string, null: false, default: "manual"

      timestamps(type: :utc_datetime)
    end

    # The gain query walks flows for an account across a date window, and the
    # anomaly check asks "has this day been accounted for at all".
    create index(:portfolio_flows, [:account_key, :occurred_on])
  end
end
