defmodule BusterClaw.Memory.Memory do
  use Ecto.Schema

  import Ecto.Changeset

  schema "memories" do
    field :created_at, :utc_datetime
    field :text, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [:created_at, :text])
    |> validate_required([:created_at, :text])
  end
end
