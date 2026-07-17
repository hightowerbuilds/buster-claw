defmodule BusterClaw.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  # The Notify subsystem's durable store. A notification is a moment the agent
  # scheduled from any entry point (chat, terminal, email, voicemail) via the
  # `notify_*` commands. `fire_at` is the absolute moment — a timer is just
  # now + duration resolved at create time — so alarms survive an app restart and
  # the scheduler recomputes the next wake on boot.
  def change do
    create table(:notifications) do
      add :kind, :string, null: false
      add :label, :string, null: false
      add :fire_at, :utc_datetime, null: false
      add :status, :string, null: false, default: "pending"
      add :source, :string, null: false, default: "manual"
      add :fired_at, :utc_datetime
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    # The scheduler's hot query: the earliest still-armed notification.
    create index(:notifications, [:status, :fire_at])
  end
end
