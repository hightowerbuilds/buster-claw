defmodule BusterClaw.Wallets.Transaction do
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Wallets.Wallet

  @kinds ~w(income expense)
  @sources ~w(manual market url integration gmail)

  schema "wallet_transactions" do
    field :kind, :string
    field :amount_cents, :integer
    field :category, :string
    field :description, :string
    field :occurred_on, :date
    field :source, :string, default: "manual"
    field :metadata, :map, default: %{}

    belongs_to :wallet, Wallet

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def sources, do: @sources

  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [
      :wallet_id,
      :kind,
      :amount_cents,
      :category,
      :description,
      :occurred_on,
      :source,
      :metadata
    ])
    |> validate_required([:wallet_id, :kind, :amount_cents, :occurred_on])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:source, @sources)
    |> validate_number(:amount_cents, greater_than: 0)
    |> assoc_constraint(:wallet)
  end
end
