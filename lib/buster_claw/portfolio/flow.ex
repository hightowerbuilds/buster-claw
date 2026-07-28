defmodule BusterClaw.Portfolio.Flow do
  @moduledoc """
  A deposit, a withdrawal, or a day reviewed and found to be neither
  (PORTFOLIO_HISTORY_ROADMAP Phase 2).

  The sign convention is enforced here rather than trusted from the caller: a
  `deposit` must be positive, a `withdrawal` negative, and `not_a_transfer`
  exactly zero. A withdrawal filed with a positive amount would *add* to the
  gain it was meant to remove — the failure would look like performance, which
  is the one direction a money bug must never fail in.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @kinds ~w(deposit withdrawal not_a_transfer)
  @sources ~w(manual agent)

  schema "portfolio_flows" do
    field :account_key, :string
    field :occurred_on, :date
    field :amount_cents, :integer, default: 0
    field :kind, :string
    field :note, :string
    field :source, :string, default: "manual"

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def sources, do: @sources

  def changeset(flow, attrs) do
    flow
    |> cast(attrs, [:account_key, :occurred_on, :amount_cents, :kind, :note, :source])
    |> validate_required([:account_key, :occurred_on, :amount_cents, :kind, :source])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:account_key, min: 1, max: 32)
    |> validate_length(:note, max: 500)
    |> validate_sign()
  end

  defp validate_sign(changeset) do
    kind = get_field(changeset, :kind)
    amount = get_field(changeset, :amount_cents)

    case {kind, amount} do
      {"deposit", amount} when is_integer(amount) and amount > 0 ->
        changeset

      {"deposit", _amount} ->
        add_error(changeset, :amount_cents, "a deposit must be a positive amount")

      {"withdrawal", amount} when is_integer(amount) and amount < 0 ->
        changeset

      {"withdrawal", _amount} ->
        add_error(changeset, :amount_cents, "a withdrawal must be a negative amount")

      {"not_a_transfer", 0} ->
        changeset

      {"not_a_transfer", _amount} ->
        add_error(changeset, :amount_cents, "a non-transfer must be zero")

      _other ->
        changeset
    end
  end
end
