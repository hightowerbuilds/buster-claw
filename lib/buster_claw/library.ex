defmodule BusterClaw.Library do
  @moduledoc "Database metadata and local filesystem artifacts for markdown documents."

  import Ecto.Query

  alias BusterClaw.Library.{Artifact, Document, Report}
  alias BusterClaw.LocalTime
  alias BusterClaw.Repo

  def library_root, do: Artifact.root()
  def ensure_directories, do: Artifact.ensure_directories()

  def list_documents do
    Document
    |> order_by([d], desc: d.date, desc: d.inserted_at)
    |> Repo.all()
  end

  def get_document!(id), do: Repo.get!(Document, id)
  def create_document(attrs), do: %Document{} |> Document.changeset(attrs) |> Repo.insert()

  def update_document(%Document{} = document, attrs),
    do: document |> Document.changeset(attrs) |> Repo.update()

  def delete_document(%Document{} = document), do: Repo.delete(document)

  def save_raw_document(attrs) do
    with {:ok, path} <- Artifact.write_raw_document(attrs),
         {:ok, parsed} <- Artifact.parse_markdown_file(path) do
      fields = parsed.fields
      relative_path = Artifact.relative_to_root(path)
      source_url = Map.get(fields, "url") || attr(attrs, :source_url)
      name = Map.get(fields, "name") || attr(attrs, :name)
      tags = Map.get(fields, "tags") || attr(attrs, :tags) || []
      date = attr(attrs, :date) || LocalTime.today()

      attrs = %{
        source_id: attr(attrs, :source_id),
        filename: Path.basename(path),
        artifact_path: relative_path,
        date: date,
        source_url: source_url,
        name: name,
        tags: %{"items" => List.wrap(tags)},
        content_hash: parsed.content_hash,
        excerpt: parsed.excerpt,
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

  def index_existing_raw_documents do
    Artifact.ensure_directories()

    Artifact.indexable_raw_files()
    |> Enum.map(&index_raw_file/1)
  end

  def index_raw_file(path) do
    with {:ok, abs_path} <- Artifact.validate_raw_path(path),
         {:ok, parsed} <- Artifact.parse_markdown_file(abs_path) do
      fields = parsed.fields
      relative_path = Artifact.relative_to_root(abs_path)
      date = date_from_path(abs_path)
      tags = Map.get(fields, "tags", [])

      attrs = %{
        filename: Path.basename(abs_path),
        artifact_path: relative_path,
        date: date,
        source_url: Map.get(fields, "url"),
        name: Map.get(fields, "name"),
        tags: %{"items" => List.wrap(tags)},
        content_hash: parsed.content_hash,
        excerpt: parsed.excerpt,
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      case Repo.get_by(Document, artifact_path: relative_path) do
        nil -> create_document(attrs)
        %Document{} = document -> update_document(document, attrs)
      end
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

  def list_reports, do: Repo.all(Report)
  def get_report!(id), do: Repo.get!(Report, id)
  def create_report(attrs), do: %Report{} |> Report.changeset(attrs) |> Repo.insert()

  def update_report(%Report{} = report, attrs),
    do: report |> Report.changeset(attrs) |> Repo.update()

  def delete_report(%Report{} = report), do: Repo.delete(report)

  defp date_from_path(path) do
    path
    |> Path.dirname()
    |> Path.basename()
    |> Date.from_iso8601()
    |> case do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end
end
