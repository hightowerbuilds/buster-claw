defmodule BusterClaw.Sketch.Store do
  @moduledoc """
  Sketches on disk: `<workspace>/sketches/<name>.json`.

  `SKETCH_ROADMAP` Phase 1 and `D9` — a sketch is a workspace file the operator
  owns, not a database row. No migration, nothing to export, and deleting one is
  deleting a file.

  ## Loading is an untrusted read

  The file is in the operator's own workspace, which means it is hand-editable by
  design — so a load is parsing input, not restoring state. Every element goes
  back through `Element.rehydrate/1`, and an element that no longer validates is
  **dropped with a log line while the rest of the sketch loads**. A single bad
  stroke should cost you that stroke, not the drawing.

  A file that is not JSON at all is a different matter: that returns an error
  rather than an empty sketch, because silently handing back a blank canvas is
  how someone saves over the drawing they were trying to recover.

  ## Names

  A sketch name is a bare filename, never a path. `resolve/1` refuses anything
  with a separator or a `..` outright rather than sanitising it — the same posture
  Pockets takes, and for the same reason: a rewritten path is a path someone
  chose that we then changed, and the interesting cases are the ones where they
  meant it.
  """

  require Logger

  alias BusterClaw.Sketch.{Assets, Document, Element, Paths}

  @doc "The directory sketches live in."
  defdelegate dir, to: Paths

  @doc """
  Absolute path for a sketch name. `{:ok, path}` or `{:error, :invalid_name}`.
  """
  defdelegate resolve(name), to: Paths, as: :document

  @doc "Sketch names on disk, alphabetical."
  def list do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, Paths.extension()))
        |> Enum.map(&Path.basename(&1, Paths.extension()))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Load a sketch. `{:ok, document}`, `{:error, :not_found}`, or
  `{:error, :unreadable}` when the file exists and is not a sketch.
  """
  def load(name) do
    with {:ok, path} <- resolve(name),
         {:ok, raw} <- read(path),
         {:ok, data} <- decode(raw, path) do
      {:ok, to_document(name, data)}
    end
  end

  @doc """
  Write a sketch, creating the directory if needed. Returns `{:ok, path}`.

  Writes to a temporary file and renames, so a crash mid-write leaves the
  previous sketch intact rather than a truncated one. The drawing is the only
  copy — there is no database behind it to recover from.
  """
  def save(name, %Document{} = doc) do
    with {:ok, path} <- resolve(name),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- encode(doc) do
      tmp = path <> ".tmp"

      with :ok <- File.write(tmp, json),
           :ok <- File.rename(tmp, path) do
        {:ok, path}
      else
        error ->
          _ = File.rm(tmp)
          error
      end
    end
  end

  @doc """
  Delete a sketch and its images. `:ok` whether or not it was there.

  The sidecar goes with the document, and that is not tidiness — it is the whole
  argument for `D11`. Deleting one and keeping the other would leave exactly the
  orphans the shared-folder alternative was rejected for.
  """
  def delete(name) do
    case resolve(name) do
      {:ok, path} ->
        _ = File.rm(path)
        _ = Assets.delete_all(name)
        :ok

      error ->
        error
    end
  end

  # --- encoding -------------------------------------------------------------

  defp encode(%Document{} = doc) do
    Jason.encode(
      %{
        "version" => 1,
        "id" => doc.id,
        "title" => doc.title,
        "created_at" => stamp(doc.created_at),
        "updated_at" => stamp(doc.updated_at),
        "elements" => Enum.map(doc.elements, &element_to_map/1)
      },
      pretty: true
    )
  end

  # Per-kind, and it MUST stay exhaustive over `Element.kinds()`.
  #
  # This was flat once — `points`, `color`, `width` for everything — and adding
  # images did not touch it. The result was worse than a crash: an image was
  # written with none of its fields, `Element.rehydrate/1` refused it on the next
  # load as `missing_source`, and the "drop a bad element, keep the drawing" rule
  # dropped it silently. The sketch simply had no picture in it, with a log line
  # nobody was reading. `store_test.exs` now round-trips every kind in
  # `Element.kinds()`, so a new kind cannot be added without teaching this.
  defp element_to_map(%Element{kind: :stroke} = element) do
    element
    |> common()
    |> Map.merge(%{
      "points" => element.points,
      "color" => element.color,
      "width" => element.width
    })
  end

  defp element_to_map(%Element{kind: :text} = element) do
    element
    |> common()
    |> Map.merge(%{
      "content" => element.content,
      "color" => element.color,
      "size" => element.size,
      "x" => element.x,
      "y" => element.y
    })
  end

  defp element_to_map(%Element{kind: :image} = element) do
    element
    |> common()
    |> Map.merge(%{
      "source" => element.source,
      "x" => element.x,
      "y" => element.y,
      "w" => element.w,
      "h" => element.h
    })
  end

  defp common(%Element{} = element) do
    %{
      "id" => element.id,
      "kind" => Atom.to_string(element.kind),
      "author" => Atom.to_string(element.author),
      "created_at" => stamp(element.created_at)
    }
  end

  defp stamp(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp stamp(_other), do: DateTime.to_iso8601(DateTime.utc_now())

  # --- decoding -------------------------------------------------------------

  defp read(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp decode(raw, path) do
    case Jason.decode(raw) do
      {:ok, data} when is_map(data) ->
        {:ok, data}

      _ ->
        Logger.warning("Sketch.Store: #{path} is not a sketch document; refusing to load it")
        {:error, :unreadable}
    end
  end

  defp to_document(name, data) do
    %Document{
      id: Map.get(data, "id") || name,
      title: Map.get(data, "title") || name,
      elements: rehydrate_elements(Map.get(data, "elements"), name),
      created_at: parse_time(Map.get(data, "created_at")),
      updated_at: parse_time(Map.get(data, "updated_at"))
    }
  end

  defp rehydrate_elements(elements, name) when is_list(elements) do
    Enum.flat_map(elements, fn attrs ->
      case Element.rehydrate(attrs) do
        {:ok, element} ->
          [element]

        {:error, reason} ->
          Logger.warning("Sketch.Store: dropping an element of #{name}: #{inspect(reason)}")
          []
      end
    end)
  end

  defp rehydrate_elements(_elements, _name), do: []

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> DateTime.utc_now()
    end
  end

  defp parse_time(_value), do: DateTime.utc_now()
end
