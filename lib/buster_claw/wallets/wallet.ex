defmodule BusterClaw.Wallets.Wallet do
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Wallets.{Budget, Transaction}

  @types ~w(business personal)

  schema "wallets" do
    field :name, :string
    field :type, :string, default: "business"
    field :currency, :string, default: "USD"
    field :balance_cents, :integer, default: 0
    field :archived, :boolean, default: false

    has_many :transactions, Transaction
    has_many :budgets, Budget

    timestamps(type: :utc_datetime)
  end

  def types, do: @types

  # NOTE: `:balance_cents` is intentionally NOT cast here. It is a cache of the
  # transaction ledger and must only ever be written by `Wallets.recompute_balance!/1`
  # (which uses `Ecto.Changeset.change/2` directly). Casting it would let the generic
  # `update_wallet/2` overwrite the ledger-derived balance with an arbitrary value.
  def changeset(wallet, attrs) do
    wallet
    |> cast(attrs, [:name, :type, :currency, :archived])
    |> validate_required([:name, :type, :currency])
    |> validate_inclusion(:type, @types)
    |> validate_length(:currency, is: 3)
  end
end
