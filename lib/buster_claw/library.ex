defmodule BusterClaw.Library do
  @moduledoc "Database metadata and local filesystem artifacts for markdown documents."

  import Ecto.Query

  alias BusterClaw.Library.{Artifact, Document}
  alias BusterClaw.LocalTime
  alias BusterClaw.Repo

  def library_root, do: Artifact.root()
  def ensure_directories, do: Artifact.ensure_directories()

  @doc "Hash a body the same way it is stored on `document.content_hash`."
  def body_hash(body), do: Artifact.body_hash(body)

  def list_documents do
    Document
    |> order_by([d], desc: d.date, desc: d.inserted_at)
    |> Repo.all()
  end

  @doc """
  List documents matching scoping options, ordered newest-first.

  Supported opts:

    * `:since` — a `Date`; only documents with `date >= since` are returned.
    * `:tag` — a string; only documents whose `tags["items"]` array contains
      this value are returned (matched in SQL against the JSON-encoded array).

  Pushing these filters into the query avoids loading the whole table just to
  filter it in memory.
  """
  def list_documents(opts) when is_list(opts) do
    Document
    |> scope_since(Keyword.get(opts, :since))
    |> scope_tag(Keyword.get(opts, :tag))
    |> order_by([d], desc: d.date, desc: d.inserted_at)
    |> Repo.all()
  end

  defp scope_since(query, nil), do: query

  defp scope_since(query, %Date{} = since),
    do: where(query, [d], d.date >= ^since)

  defp scope_tag(query, nil), do: query
  defp scope_tag(query, ""), do: query

  defp scope_tag(query, tag) when is_binary(tag) do
    # tags is stored as %{"items" => [...]}; match the JSON-encoded element so
    # the filter runs in SQL rather than in memory. The surrounding quotes guard
    # against substring matches on other tags.
    pattern = "%" <> Jason.encode!(tag) <> "%"
    where(query, [d], like(fragment("CAST(? AS TEXT)", d.tags), ^pattern))
  end

  def get_document!(id), do: Repo.get!(Document, id)
  def create_document(attrs), do: %Document{} |> Document.changeset(attrs) |> Repo.insert()

  def update_document(%Document{} = document, attrs),
    do: document |> Document.changeset(attrs) |> Repo.update()

  def delete_document(%Document{} = document), do: Repo.delete(document)

  def save_raw_document(attrs) do
    with {:ok, written} <- Artifact.write_raw_document(attrs) do
      %{path: path, fields: fields} = written
      relative_path = Artifact.relative_to_root(path)
      source_url = Map.get(fields, "url") || attr(attrs, :source_url)
      name = Map.get(fields, "name") || attr(attrs, :name)
      tags = Map.get(fields, "tags") || attr(attrs, :tags) || []
      date = attr(attrs, :date) || LocalTime.today()

      attrs = %{
        filename: Path.basename(path),
        artifact_path: relative_path,
        date: date,
        source_url: source_url,
        name: name,
        tags: %{"items" => List.wrap(tags)},
        content_hash: written.content_hash,
        excerpt: written.excerpt,
        status: attr(attrs, :status) || "fetched",
        fetched_at: attr(attrs, :fetched_at) || timestamp()
      }

      case Repo.get_by(Document, artifact_path: relative_path) do
        nil -> create_document(attrs)
        %Document{} = document -> update_document(document, attrs)
      end
    end
  end

  def read_raw_document(%Document{} = document) do
    document.artifact_path
    |> absolute_artifact_path()
    |> Artifact.read_raw_document()
  end

  def delete_raw_document(%Document{} = document) do
    abs_path = absolute_artifact_path(document.artifact_path)

    with :ok <- Artifact.delete_raw_document(abs_path),
         {:ok, document} <- update_document(document, %{status: "deleted"}) do
      {:ok, document}
    end
  end

  def absolute_artifact_path(relative_or_abs_path) do
    path = Path.expand(relative_or_abs_path)
    root = Path.expand(library_root())

    if String.starts_with?(path, root <> "/") do
      path
    else
      Path.join(root, relative_or_abs_path)
    end
  end

  defp attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end
end
