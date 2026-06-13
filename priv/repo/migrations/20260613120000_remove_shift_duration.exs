defmodule BusterClaw.Repo.Migrations.RemoveShiftDuration do
  use Ecto.Migration

  # Shifts now run until stopped (shift_stop / kill-switch) — there is no fixed
  # duration or precomputed window. Drop the columns that encoded that concept.
  def up do
    alter table(:shifts) do
      remove :ends_at
      remove :duration_hours
    end
  end

  def down do
    alter table(:shifts) do
      add :ends_at, :utc_datetime
      add :duration_hours, :integer, null: false, default: 12
    end
  end
end
