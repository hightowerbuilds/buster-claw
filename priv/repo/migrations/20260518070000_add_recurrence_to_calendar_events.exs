defmodule BusterClaw.Repo.Migrations.AddRecurrenceToCalendarEvents do
  use Ecto.Migration

  def change do
    alter table(:calendar_events) do
      add :frequency, :string
      add :recur_until, :date
    end
  end
end
