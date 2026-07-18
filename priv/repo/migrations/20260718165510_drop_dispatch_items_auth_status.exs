defmodule BusterClaw.Repo.Migrations.DropDispatchItemsAuthStatus do
  use Ecto.Migration

  # `auth_status` was a decoy: written only as its "unverified" default, read by
  # nothing (the provenance gate is the `trusted` column), and misleading on
  # PIN-verified voicemail rows. Same class as the `telephony_contacts.trusted`
  # column dropped on 07-13 (ed048c1) — an unwired switch a future change could
  # bind to and trust.
  def change do
    alter table(:dispatch_items) do
      remove :auth_status, :string, null: false, default: "unverified"
    end
  end
end
