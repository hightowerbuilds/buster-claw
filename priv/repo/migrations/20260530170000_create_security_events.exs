defmodule BusterClaw.Repo.Migrations.CreateSecurityEvents do
  use Ecto.Migration

  def change do
    create table(:security_events) do
      add :category, :string, null: false
      add :severity, :string, null: false
      add :message, :string, null: false
      add :caller, :string
      add :metadata, :map, null: false, default: %{}
      add :acknowledged_at, :utc_datetime

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:security_events, [:inserted_at])
    create index(:security_events, [:severity])
    create index(:security_events, [:acknowledged_at])
  end
end
