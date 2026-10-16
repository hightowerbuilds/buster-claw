defmodule BusterClaw.Repo.Migrations.DropTelephonyEvents do
  @moduledoc """
  The phone left on 10-15 (PHONE_REMOVAL_ROADMAP, D4). `telephony_events` held
  the drained voicemail and SMS rows; nothing reads or writes it any more.
  `telephony_contacts` was already dropped by `20260713040000_unify_contacts`.

  Forward only: `down` recreates nothing, because there is no code left to fill
  the table, and a recreated empty table would only look like a feature.
  Recordings and transcripts already filed in the Library stay where they are.
  """
  use Ecto.Migration

  def up do
    drop_if_exists table(:telephony_events)
  end

  def down, do: :ok
end
