defmodule BusterClaw.Sources.Source do
  use Ecto.Schema

  import Ecto.Changeset

  @types ~w(article documentation rss youtube_transcript browser)

  schema "sources" do
    field :url, :string
    field :type, :string
    field :name, :string
    field :tags, :map, default: %{}
    field :tags_text, :string, virtual: true
    field :browser_engine, :string
    field :cookies, :map, default: %{}
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:url, :type, :name, :tags, :tags_text, :browser_engine, :cookies, :enabled])
    |> validate_required([:url, :type])
    |> validate_inclusion(:type, @types)
    |> unique_constraint(:url)
  end
end
