defmodule BusterClaw.Providers.Provider do
  use Ecto.Schema

  import Ecto.Changeset

  @types ~w(ollama openrouter openai anthropic gemini codex custom)

  schema "providers" do
    field :name, :string
    field :type, :string
    field :base_url, :string
    field :api_key, BusterClaw.Encrypted
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
    |> maybe_require_api_key()
    |> unique_constraint(:name)
  end

  defp maybe_require_api_key(changeset) do
    case get_field(changeset, :type) do
      "ollama" -> changeset
      _ -> validate_required(changeset, [:api_key])
    end
  end
end
