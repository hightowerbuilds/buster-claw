defmodule BusterClaw.Notifications.Notification do
  use Ecto.Schema

  import Ecto.Changeset

  # timer   — a relative countdown; `fire_at` is now + duration at create time
  # alarm   — an absolute clock moment
  # reminder — fires immediately (a message with no countdown)
  @kinds ~w(timer alarm reminder)
  # pending — armed; snoozed — re-armed after a fire; fired/dismissed — terminal
  @statuses ~w(pending snoozed fired dismissed)
  # Where the agent was when it scheduled this. `voicemail` is inbound-only for
  # now; `sms` will join when outbound telephony lands (both are command callers).
  @sources ~w(chat terminal email voicemail manual)

  schema "notifications" do
    field :kind, :string
    field :label, :string
    field :fire_at, :utc_datetime
    field :status, :string, default: "pending"
    field :source, :string, default: "manual"
    field :fired_at, :utc_datetime
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses
  def sources, do: @sources

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:kind, :label, :fire_at, :status, :source, :fired_at, :metadata])
    |> validate_required([:kind, :label, :fire_at, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:label, min: 1, max: 500)
  end
end
