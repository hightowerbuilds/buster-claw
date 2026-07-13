defmodule BusterClaw.Repo.Migrations.UnifyContacts do
  @moduledoc """
  One contact, both channels — and the death of a decoy.

  `telephony_contacts` was phone-only and carried a `trusted` boolean that
  **nothing ever read** (grep it in the old tree: zero call sites) while
  defaulting to `true`. The real trust gates were, and remain, the markdown
  policy files: `memory/trusted-email-senders.md` (read by `Google.GmailSync`)
  and `memory/trusted-phone-numbers.md` (read by `Telephony.Drain`). An unwired
  switch that defaults to *trusted* is a hole waiting for someone to bind a
  checkbox to it, so it does not survive into the new table.

  Trust is therefore **derived, never stored** — see `BusterClaw.Contacts.trusted?/1`.
  A contact row is identity and presentation only: who they are, how to reach
  them, and what their face looks like.

  Drop-and-create rather than alter: SQLite cannot relax a NOT NULL column
  without a full table rebuild (`number` must become nullable — an email-only
  contact has no phone), and the old table held nothing but the demo seed from
  `priv/repo/seeds/telephony_demo.exs`. Nothing real is lost. If you somehow
  have contacts you care about, export them before migrating.
  """
  use Ecto.Migration

  def up do
    drop table(:telephony_contacts)

    create table(:contacts) do
      add :name, :string, null: false
      # Both nullable, but the changeset requires at least one: a contact with
      # neither identifier can never be matched to an inbound event.
      add :phone, :string
      add :email, :string
      add :face_shader, :string
      add :face_seed, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    # SQLite treats NULLs as distinct in a unique index, so these permit many
    # phone-less (or email-less) contacts while still forbidding duplicates.
    create unique_index(:contacts, [:phone])
    create unique_index(:contacts, [:email])
  end

  def down do
    drop table(:contacts)

    create table(:telephony_contacts) do
      add :name, :string, null: false
      add :number, :string, null: false
      add :face_shader, :string
      add :face_seed, :integer, null: false, default: 0
      add :trusted, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:telephony_contacts, [:number])
  end
end
