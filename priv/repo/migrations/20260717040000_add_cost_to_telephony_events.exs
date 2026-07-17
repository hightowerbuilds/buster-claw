defmodule BusterClaw.Repo.Migrations.AddCostToTelephonyEvents do
  use Ecto.Migration

  # Per-message Twilio cost (VOICEMAIL_COST_ROADMAP.md). Twilio never sends price
  # in a webhook — it lives on the REST resources and populates asynchronously —
  # so these fill in on a retryable back-fill, not at drain time. `cost_micros` is
  # the total in micro-USD (integer, no float drift: $0.25 = 250_000), summed from
  # the call/recording/transcription resource prices. `cost_synced_at` is set only
  # once all components are final; null means "not priced yet." The per-component
  # breakdown and the CallSid/TranscriptionSid needed to fetch them ride in the
  # existing `metadata` map, so no schema churn for those.
  def change do
    alter table(:telephony_events) do
      add :cost_micros, :integer
      add :cost_currency, :string
      add :cost_synced_at, :utc_datetime
    end
  end
end
