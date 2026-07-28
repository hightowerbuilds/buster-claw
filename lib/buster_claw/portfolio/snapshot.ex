defmodule BusterClaw.Portfolio.Snapshot do
  @moduledoc """
  One account's balance reading on one market day (PORTFOLIO_HISTORY_ROADMAP
  Phase 0).

  Money is integer cents. The changeset is the last gate before a model-sourced
  number becomes permanent history, so it is deliberately strict: a negative
  value, a missing key, or an unknown source is refused rather than stored. The
  order-of-magnitude check against the previous reading lives in
  `BusterClaw.Portfolio` — it needs the prior row, which a changeset doesn't
  have.
  """
  use Ecto.Schema

  import Ecto.Changeset

  # tab_open   — recorded as a side effect of the Trading panel's stage-1 fetch
  # daily_pump — recorded by the supervised recorder (Phase 1)
  # manual     — entered or corrected by the operator
  @sources ~w(tab_open daily_pump manual)

  schema "portfolio_snapshots" do
    field :account_key, :string
    field :label, :string
    field :captured_on, :date
    field :value_cents, :integer
    field :cash_cents, :integer
    field :buying_power_cents, :integer
    field :source, :string, default: "tab_open"

    timestamps(type: :utc_datetime)
  end

  def sources, do: @sources

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :account_key,
      :label,
      :captured_on,
      :value_cents,
      :cash_cents,
      :buying_power_cents,
      :source
    ])
    |> validate_required([:account_key, :label, :captured_on, :value_cents, :source])
    |> validate_inclusion(:source, @sources)
    |> validate_length(:account_key, min: 1, max: 32)
    |> validate_length(:label, min: 1, max: 120)
    # A brokerage account cannot be worth less than nothing, and a negative here
    # would invert a gain into a loss for every day after it.
    |> validate_number(:value_cents, greater_than_or_equal_to: 0)
    |> unique_constraint([:account_key, :captured_on])
  end
end
