defmodule BusterClaw.Telephony.Event do
  @moduledoc """
  One phone event — a voicemail, an SMS, or a bare call. Inbound voicemails are
  mirrored from the Supabase relay by the drain; that is the only producer of
  rows in this table today.

  `direction` accepts `outbound` and `kind` accepts `sms`, but **nothing writes
  either** — no Twilio REST client exists and there is no `sms` edge function.
  The values are here so the schema doesn't have to change when those land; see
  `BusterClaw.Telephony` for the full built-vs-unbuilt picture.

  `recording_path` is relative to the Library root (served to the panel by
  `TelephonyRecordingController`); `heard_at` is the answering machine's
  blinking light.
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
    # The caller-PIN verdict, carried from the relay row. Only a PIN-verified call
    # is trusted work; caller ID alone is a claim. See `BusterClaw.Telephony.Drain`.
    field :verified, :boolean, default: false
    field :metadata, :map, default: %{}
    # Per-message Twilio cost, back-filled from the REST resources (prices lag,
    # so nil = not priced yet). See VOICEMAIL_COST_ROADMAP.md.
    field :cost_micros, :integer
    field :cost_currency, :string
    field :cost_synced_at, :utc_datetime

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
      :verified,
      :metadata,
      :cost_micros,
      :cost_currency,
      :cost_synced_at,
      :document_id
    ])
    |> validate_required([:direction, :kind, :from_number, :to_number, :occurred_at])
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:twilio_sid)
  end
end
