defmodule BusterClaw.Telephony.Event do
  @moduledoc """
  One phone event — a voicemail, an SMS, or a bare call. Inbound events are
  mirrored from the Supabase relay by the drain; outbound events are recorded
  when the Mac sends them. `recording_path` is relative to the Library root
  (served to the panel by `TelephonyRecordingController`); `heard_at` is the
  answering machine's blinking light.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @directions ~w(inbound outbound)
  @kinds ~w(voicemail sms call)

  schema "telephony_events" do
    field :direction, :string
    field :kind, :string
    field :from_number, :string
    field :to_number, :string
    field :body, :string
    field :duration_seconds, :integer
    field :recording_path, :string
    field :transcript, :string
    field :twilio_sid, :string
    field :occurred_at, :utc_datetime
    field :heard_at, :utc_datetime
    field :metadata, :map, default: %{}

    belongs_to :document, BusterClaw.Library.Document

    timestamps(type: :utc_datetime)
  end

  def directions, do: @directions
  def kinds, do: @kinds

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :direction,
      :kind,
      :from_number,
      :to_number,
      :body,
      :duration_seconds,
      :recording_path,
      :transcript,
      :twilio_sid,
      :occurred_at,
      :heard_at,
      :metadata,
      :document_id
    ])
    |> validate_required([:direction, :kind, :from_number, :to_number, :occurred_at])
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:twilio_sid)
  end
end
