defmodule BusterClaw.Repo.Migrations.AddShiftUnattended do
  use Ecto.Migration

  # Marks a shift as unattended: the Dispatcher work-pump is allowed to spawn
  # headless agent runs against the Dispatch queue for it. Attended shifts (the
  # default) are worked by a human-launched agent in the in-app terminal, so the
  # pump leaves them alone.
  def change do
    alter table(:shifts) do
      add :unattended, :boolean, default: false, null: false
    end
  end
end
