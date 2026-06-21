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

  def changeset(wallet, attrs) do
    wallet
    |> cast(attrs, [:name, :type, :currency, :balance_cents, :archived])
    |> validate_required([:name, :type, :currency])
    |> validate_inclusion(:type, @types)
    |> validate_length(:currency, is: 3)
  end
end
