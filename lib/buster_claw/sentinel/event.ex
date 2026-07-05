defmodule BusterClaw.Sentinel.Event do
  @moduledoc """
  A persisted, append-only security/audit event. Written by `BusterClaw.Sentinel`
  and surfaced in the live alert center. Never updated except to stamp
  `acknowledged_at`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @severities ~w(info notice warning critical)
  @categories ~w(security_block command_invoke outbound_send untrusted_ingest settings_change)

  @derive {Jason.Encoder,
           only: [
             :id,
             :category,
             :severity,
             :message,
             :caller,
             :metadata,
             :acknowledged_at,
             :inserted_at
           ]}
  schema "security_events" do
    field :category, :string
    field :severity, :string
    field :message, :string
    field :caller, :string
    field :metadata, :map, default: %{}
    field :acknowledged_at, :utc_datetime

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:category, :severity, :message, :caller, :metadata, :acknowledged_at])
    |> validate_required([:category, :severity, :message])
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:severity, @severities)
  end

  def severities, do: @severities
  def categories, do: @categories
end
