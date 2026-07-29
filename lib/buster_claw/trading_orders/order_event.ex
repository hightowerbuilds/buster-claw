defmodule BusterClaw.TradingOrders.OrderEvent do
  @moduledoc "One immutable state transition in a trading order's audit trail."
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.TradingOrders.OrderIntent

  schema "trading_order_events" do
    field :event_type, :string
    field :payload, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    belongs_to :order_intent, OrderIntent

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:order_intent_id, :event_type, :payload, :occurred_at])
    |> validate_required([:order_intent_id, :event_type, :payload, :occurred_at])
    |> validate_length(:event_type, min: 1, max: 64)
    |> foreign_key_constraint(:order_intent_id)
  end
end
