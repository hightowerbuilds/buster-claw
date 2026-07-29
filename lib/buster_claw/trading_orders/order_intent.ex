defmodule BusterClaw.TradingOrders.OrderIntent do
  @moduledoc """
  A non-executable equity order draft and its audited workflow state.

  Money is stored as integer cents and share quantities as millionths. The
  record never stores a confirmation phrase in plaintext.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(draft previewed submitting accepted filled rejected cancelled expired failed unknown)
  @sides ~w(buy sell)
  @order_types ~w(market limit)
  @time_in_force ~w(day gtc)
  @symbol_re ~r/\A[A-Z][A-Z0-9.]{0,9}\z/

  schema "trading_order_intents" do
    field :public_id, :string
    field :status, :string, default: "draft"
    field :account_id, :string
    field :account_label, :string
    field :symbol, :string
    field :side, :string
    field :quantity_micros, :integer
    field :notional_cents, :integer
    field :order_type, :string
    field :limit_price_cents, :integer
    field :time_in_force, :string

    field :quote_cents, :integer
    field :buying_power_cents, :integer
    field :estimated_notional_cents, :integer
    field :concentration_bps, :integer
    field :broker_preview, :map
    field :broker_preview_id, :string
    field :broker_timestamp, :utc_datetime_usec

    field :preview_payload, :map
    field :preview_digest, :string
    field :confirmation_digest, :string
    field :confirmation_expires_at, :utc_datetime_usec
    field :confirmed_at, :utc_datetime_usec

    field :client_order_id, :string
    field :broker_order_id, :string
    field :broker_status, :string
    field :broker_response, :map
    field :submitted_at, :utc_datetime_usec
    field :last_reconciled_at, :utc_datetime_usec
    field :failure_reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  def draft_changeset(intent, attrs) do
    intent
    |> cast(attrs, [
      :public_id,
      :status,
      :account_id,
      :account_label,
      :symbol,
      :side,
      :quantity_micros,
      :notional_cents,
      :order_type,
      :limit_price_cents,
      :time_in_force,
      :client_order_id
    ])
    |> validate_required([
      :public_id,
      :status,
      :account_id,
      :symbol,
      :side,
      :order_type,
      :time_in_force,
      :client_order_id
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:side, @sides)
    |> validate_inclusion(:order_type, @order_types)
    |> validate_inclusion(:time_in_force, @time_in_force)
    |> validate_format(:symbol, @symbol_re)
    |> validate_length(:account_id, min: 8, max: 255)
    |> validate_length(:account_label, max: 120)
    |> validate_number(:quantity_micros, greater_than: 0)
    |> validate_number(:notional_cents, greater_than: 0)
    |> validate_number(:limit_price_cents, greater_than: 0)
    |> validate_amount()
    |> validate_limit_price()
    |> validate_notional_order_type()
    |> unique_constraint(:public_id)
    |> unique_constraint(:client_order_id)
  end

  defp validate_amount(changeset) do
    quantity = get_field(changeset, :quantity_micros)
    notional = get_field(changeset, :notional_cents)

    if (is_integer(quantity) and is_nil(notional)) or
         (is_nil(quantity) and is_integer(notional)) do
      changeset
    else
      add_error(changeset, :quantity_micros, "provide exactly one of quantity or notional")
    end
  end

  defp validate_limit_price(changeset) do
    order_type = get_field(changeset, :order_type)
    limit_price = get_field(changeset, :limit_price_cents)

    cond do
      order_type == "limit" and not is_integer(limit_price) ->
        add_error(changeset, :limit_price_cents, "is required for a limit order")

      order_type == "market" and not is_nil(limit_price) ->
        add_error(changeset, :limit_price_cents, "must be empty for a market order")

      true ->
        changeset
    end
  end

  defp validate_notional_order_type(changeset) do
    if is_integer(get_field(changeset, :notional_cents)) and
         get_field(changeset, :order_type) != "market" do
      add_error(changeset, :notional_cents, "is only supported for market orders")
    else
      changeset
    end
  end
end
