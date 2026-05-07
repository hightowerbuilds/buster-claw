defmodule BusterClaw.Sources do
  @moduledoc "Structured source configuration for ingestion."

  alias BusterClaw.Repo
  alias BusterClaw.Sources.Source

  def list_sources, do: Repo.all(Source)
  def get_source!(id), do: Repo.get!(Source, id)
  def create_source(attrs), do: %Source{} |> Source.changeset(attrs) |> Repo.insert()

  def update_source(%Source{} = source, attrs),
    do: source |> Source.changeset(attrs) |> Repo.update()

  def delete_source(%Source{} = source), do: Repo.delete(source)
end
