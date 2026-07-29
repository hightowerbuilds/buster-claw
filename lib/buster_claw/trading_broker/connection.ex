defmodule BusterClaw.TradingBroker.Connection do
  @moduledoc "Encrypted OAuth state for one application-owned broker connection."
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.TradingBroker.Account

  @statuses ~w(disconnected authorizing connected reconnect_required error)

  @derive {Inspect, except: [:access_token, :refresh_token]}

  schema "trading_broker_connections" do
    field :provider, :string
    field :client_id, :string
    field :access_token, BusterClaw.Encrypted, redact: true
    field :refresh_token, BusterClaw.Encrypted, redact: true
    field :access_token_expires_at, :utc_datetime_usec
    field :scope, :string
    field :status, :string, default: "disconnected"
    field :connected_at, :utc_datetime_usec
    field :last_checked_at, :utc_datetime_usec
    field :last_error, :string

    has_many :accounts, Account

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :provider,
      :client_id,
      :access_token,
      :refresh_token,
      :access_token_expires_at,
      :scope,
      :status,
      :connected_at,
      :last_checked_at,
      :last_error
    ])
    |> validate_required([:provider, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:provider, min: 1, max: 40)
    |> validate_length(:client_id, max: 500)
    |> validate_length(:scope, max: 500)
    |> validate_length(:last_error, max: 1_000)
    |> unique_constraint(:provider)
  end
end
