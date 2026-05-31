defmodule BusterClaw.Repo.Migrations.CreateAppSettings do
  use Ecto.Migration

  def change do
    create table(:app_settings) do
      add :key, :string, null: false
      add :value, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:app_settings, [:key])
  end
end
