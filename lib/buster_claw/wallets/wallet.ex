defmodule BusterClaw.Wallets.Wallet do
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Wallets.{Budget, Transaction}

  @types ~w(business personal)
  @templates ~w(none busterclaw)

  schema "wallets" do
    field :name, :string
    field :type, :string, default: "business"
    field :template, :string, default: "none"
    field :currency, :string, default: "USD"
    field :balance_cents, :integer, default: 0
    field :archived, :boolean, default: false
    # Monthly model/subscription costs as `%{"provider" => cents}` (e.g.
    # %{"anthropic" => 2000}). Set only via `Wallets.set_model_costs/2`, not the
    # generic changeset, so a bare `update_wallet/2` can't scribble over it.
    field :model_costs, :map, default: %{}

    has_many :transactions, Transaction
    has_many :budgets, Budget

    timestamps(type: :utc_datetime)
  end

  def types, do: @types
  def templates, do: @templates

  # NOTE: `:balance_cents` is intentionally NOT cast here. It is a cache of the
  # transaction ledger and must only ever be written by `Wallets.recompute_balance!/1`
  # (which uses `Ecto.Changeset.change/2` directly). Casting it would let the generic
  # `update_wallet/2` overwrite the ledger-derived balance with an arbitrary value.
  def changeset(wallet, attrs) do
    wallet
    |> cast(attrs, [:name, :type, :template, :currency, :archived])
    |> validate_required([:name, :type, :template, :currency])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:template, @templates)
    |> validate_length(:currency, is: 3)
  end
end
