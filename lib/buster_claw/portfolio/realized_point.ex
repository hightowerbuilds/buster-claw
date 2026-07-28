defmodule BusterClaw.Portfolio.RealizedPoint do
  @moduledoc """
  One bucket of realized profit & loss for one account
  (PORTFOLIO_HISTORY_ROADMAP Phase 3).

  Unlike `Portfolio.Snapshot`, `realized_cents` is **signed** — a losing month is
  a real result, not a corrupt reading, and a non-negative validation here would
  silently discard exactly the data a gain chart exists to show.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "realized_pnl_points" do
    field :account_key, :string
    field :bucket_on, :date
    field :realized_cents, :integer, default: 0
    field :trades, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(point, attrs) do
    point
    |> cast(attrs, [:account_key, :bucket_on, :realized_cents, :trades])
    |> validate_required([:account_key, :bucket_on, :realized_cents, :trades])
    |> validate_length(:account_key, min: 1, max: 32)
    |> validate_number(:trades, greater_than_or_equal_to: 0)
    |> unique_constraint([:account_key, :bucket_on])
  end
end
