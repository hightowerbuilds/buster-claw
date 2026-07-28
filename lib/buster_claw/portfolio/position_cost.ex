defmodule BusterClaw.Portfolio.PositionCost do
  @moduledoc """
  One holding's cost basis in one account (TRADING_TAB_ROADMAP Phase 3),
  aggregated from its open tax lots.

  `cost_basis_cents` may be nil — the tax-lot tool failing for one symbol must
  not erase the position, and a nil basis renders as "unavailable", never as
  zero (zero would claim the shares were free).
  """
  use Ecto.Schema

  import Ecto.Changeset

  @symbol_re ~r/\A[A-Z][A-Z0-9.]{0,9}\z/

  schema "position_costs" do
    field :account_key, :string
    field :symbol, :string
    field :quantity, :float
    field :lots, :integer, default: 0
    field :cost_basis_cents, :integer
    field :as_of, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(cost, attrs) do
    cost
    |> cast(attrs, [:account_key, :symbol, :quantity, :lots, :cost_basis_cents, :as_of])
    |> validate_required([:account_key, :symbol, :quantity, :as_of])
    |> validate_format(:symbol, @symbol_re)
    |> validate_length(:account_key, min: 1, max: 32)
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:lots, greater_than_or_equal_to: 0)
    |> validate_number(:cost_basis_cents, greater_than_or_equal_to: 0)
    |> unique_constraint([:account_key, :symbol])
  end
end
