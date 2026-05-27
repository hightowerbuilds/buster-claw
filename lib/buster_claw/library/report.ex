defmodule BusterClaw.Library.Report do
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Library.Document
  alias BusterClaw.Providers.Provider

  schema "reports" do
    belongs_to :document, Document
    belongs_to :provider, Provider

    field :filename, :string
    field :artifact_path, :string
    field :source_file, :string
    field :source_url, :string
    field :model, :string
    field :tags, :map, default: %{}
    field :generated_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :document_id,
      :provider_id,
      :filename,
      :artifact_path,
      :source_file,
      :source_url,
      :model,
      :tags,
      :generated_at
    ])
    |> validate_required([:filename, :artifact_path])
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:provider_id)
    |> unique_constraint(:artifact_path)
  end
end
