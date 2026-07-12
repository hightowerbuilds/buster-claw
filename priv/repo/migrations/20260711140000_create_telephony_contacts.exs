defmodule BusterClaw.Repo.Migrations.CreateTelephonyContacts do
  @moduledoc """
  BusterPhone's contact list — names for numbers, plus each contact's
  "shaderface": either the built-in generative face (seeded by `face_seed`) or
  a custom WGSL face from `<workspace>/shaders/` (`face_shader`). `trusted` is
  the future Phase-2 SMS gate: only trusted numbers reach the dispatch queue.
  """
  use Ecto.Migration

  def change do
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
