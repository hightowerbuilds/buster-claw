defmodule BusterClaw.Repo.Migrations.ExtendCalendarEvents do
  use Ecto.Migration

  def change do
    alter table(:calendar_events) do
      add :start_time, :time
      add :end_time, :time
      add :color, :string, default: "neutral", null: false
    end
  end
end
