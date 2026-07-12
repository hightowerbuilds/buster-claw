defmodule BusterClaw.Repo.Migrations.CreateTelephonyEvents do
  @moduledoc """
  Local mirror of phone traffic (BusterPhone): voicemails, SMS, bare calls.
  Inbound rows are drained from the Supabase relay; outbound rows are recorded
  at send time. Each row may pair with a human-readable Library doc via
  `document_id`, the same structured-row + doc pairing as `integration_runs`.
  """
  use Ecto.Migration

  def change do
    create table(:telephony_events) do
      add :direction, :string, null: false
      add :kind, :string, null: false
      add :from_number, :string, null: false
      add :to_number, :string, null: false
      add :body, :text
      add :duration_seconds, :integer
      add :recording_path, :string
      add :transcript, :text
      add :twilio_sid, :string
      add :occurred_at, :utc_datetime, null: false
      add :heard_at, :utc_datetime
      add :document_id, references(:documents, on_delete: :nilify_all)
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:telephony_events, [:twilio_sid])
    create index(:telephony_events, [:occurred_at])
    create index(:telephony_events, [:kind])
    create index(:telephony_events, [:from_number])
  end
end
