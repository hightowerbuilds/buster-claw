defmodule BusterClaw.TradingBroker.Account do
  @moduledoc """
  Structured brokerage account identity.

  `account_key` is an application HMAC; the provider account identifier remains
  encrypted and is only resolved inside the direct broker adapter.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.TradingBroker.Connection

  @derive {Inspect, except: [:broker_account_id]}

  schema "trading_broker_accounts" do
    field :account_key, :string
    field :broker_account_id, BusterClaw.Encrypted, redact: true
    field :label, :string
    field :agentic, :boolean, default: false
    field :can_trade, :boolean, default: false
    field :metadata, :map, default: %{}
    field :broker_timestamp, :utc_datetime_usec
    field :fetched_at, :utc_datetime_usec

    belongs_to :connection, Connection

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :connection_id,
      :account_key,
      :broker_account_id,
      :label,
      :agentic,
      :can_trade,
      :metadata,
      :broker_timestamp,
      :fetched_at
    ])
    |> validate_required([
      :connection_id,
      :account_key,
      :broker_account_id,
      :label,
      :agentic,
      :can_trade,
      :metadata,
      :fetched_at
    ])
    |> validate_length(:account_key, min: 32, max: 64)
    |> validate_length(:label, min: 1, max: 120)
    |> foreign_key_constraint(:connection_id)
    |> unique_constraint([:connection_id, :account_key])
  end
end
