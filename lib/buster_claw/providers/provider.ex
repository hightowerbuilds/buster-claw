defmodule BusterClaw.Providers.Provider do
  use Ecto.Schema

  import Ecto.Changeset

  @types ~w(ollama openrouter openai anthropic custom)

  schema "providers" do
    field :name, :string
    field :type, :string
    field :base_url, :string
    field :api_key, :string
    field :model, :string
    field :active, :boolean, default: false
    field :priority, :integer, default: 100

    timestamps(type: :utc_datetime)
  end

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:name, :type, :base_url, :api_key, :model, :active, :priority])
    |> validate_required([:name, :type, :model])
    |> validate_inclusion(:type, @types)
    |> unique_constraint(:name)
  end
end
