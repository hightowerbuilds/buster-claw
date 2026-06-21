defmodule BusterClaw.Wallets.Budget do
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Wallets.Wallet

  # "YYYY-MM"
  @month_format ~r/^\d{4}-(0[1-9]|1[0-2])$/

  schema "wallet_budgets" do
    field :month, :string
    field :income_target_cents, :integer, default: 0
    field :expense_target_cents, :integer, default: 0
    field :savings_target_cents, :integer, default: 0

    belongs_to :wallet, Wallet

    timestamps(type: :utc_datetime)
  end

  def changeset(budget, attrs) do
    budget
    |> cast(attrs, [
      :wallet_id,
      :month,
      :income_target_cents,
      :expense_target_cents,
      :savings_target_cents
    ])
    |> validate_required([:wallet_id, :month])
    |> validate_format(:month, @month_format, message: "must be in YYYY-MM format")
    |> validate_number(:income_target_cents, greater_than_or_equal_to: 0)
    |> validate_number(:expense_target_cents, greater_than_or_equal_to: 0)
    |> validate_number(:savings_target_cents, greater_than_or_equal_to: 0)
    |> assoc_constraint(:wallet)
    |> unique_constraint([:wallet_id, :month])
  end
end
