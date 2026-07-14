defmodule BusterClaw.Repo.Migrations.AddVerifiedToTelephonyEvents do
  use Ecto.Migration

  # The verdict of the caller-PIN gate, mirrored onto the local voicemail row the
  # drain writes. The remote `telephony_events` table gained the same column in
  # supabase/migrations/20260714030000_phone_pins.sql; the drain reads it and only
  # enqueues a trusted caller's voicemail as agent work when the call was also
  # PIN-verified. Default false so any row that skipped the gate is untrusted by
  # construction — caller ID alone is a claim, not a credential.
  def change do
    alter table(:telephony_events) do
      add :verified, :boolean, null: false, default: false
    end
  end
end
