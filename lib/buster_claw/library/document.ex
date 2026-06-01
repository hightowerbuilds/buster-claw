defmodule BusterClaw.Library.Document do
  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(fetched queued analyzing analyzed failed deleted)

  schema "documents" do
    field :filename, :string
    field :artifact_path, :string
    field :date, :date
    field :source_url, :string
    field :name, :string
    field :tags, :map, default: %{}
    field :content_hash, :string
    field :status, :string, default: "fetched"
    field :excerpt, :string
    field :fetched_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :filename,
      :artifact_path,
      :date,
      :source_url,
      :name,
      :tags,
      :content_hash,
      :status,
      :excerpt,
      :fetched_at
    ])
    |> validate_required([:filename, :artifact_path, :status])
    |> unique_constraint(:artifact_path)
  end
end
