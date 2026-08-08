defmodule BusterClaw.Notes do
  @moduledoc """
  The operator's Markdown notebook.

  Notes are ordinary `.md` and `.markdown` files beneath `<workspace>/notes/`.
  Files remain readable and editable outside Buster Claw; this module supplies
  the containment, UTF-8, size, atomic-write, and optimistic-concurrency rules
  needed by the homepage editor.

  The activity record is intentionally separate in `BusterClaw.Journal`.
  """

  alias BusterClaw.FileManager
  alias BusterClaw.Library.Artifact

  @extensions [".md", ".markdown"]
  @max_body_bytes 1_000_000
  @max_title_length 120
  @topic "notes"

  @doc "Absolute path to the workspace Notes vault."
  def dir, do: Artifact.workspace_path("notes")

  @doc "Create the Notes vault if it does not exist."
  def ensure do
    File.mkdir_p(dir())
  end

  @doc "Subscribe the calling process to Notes create/save/delete events."
  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  @doc """
  List Markdown notes recursively, foldered notes first and then loose ones,
  alphabetically within each group.

  A notebook rail is browsed by name, not by recency, and grouping this way is
  what lets the UI draw one folder heading per run of paths.
  """
  def list(query \\ nil) do
    notes = walk(dir(), "")

    notes =
      case query |> to_string() |> String.trim() |> String.downcase() do
        "" -> notes
        term -> Enum.filter(notes, &String.contains?(String.downcase(&1.path), term))
      end

    Enum.sort_by(notes, &sort_key/1)
  end

  @doc "Folder paths beneath the vault, relative to it and alphabetical."
  def folders do
    dir() |> walk_folders("") |> Enum.sort()
  end

  @doc "Read a note by its path relative to the Notes vault."
  def get(path) do
    with {:ok, absolute} <- safe_note_path(path),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(absolute),
         :ok <- validate_size(size),
         {:ok, body} <- File.read(absolute),
         true <- String.valid?(body) do
      note(path, body, absolute)
    else
      {:error, :enoent} -> nil
      {:error, reason} -> {:error, reason}
      false -> {:error, :binary}
      _ -> {:error, :not_a_file}
    end
  end

  @doc "Create an empty note in `folder`, adding `.md` when needed."
  def create(title, folder \\ "")

  def create(title, folder) when is_binary(title) and is_binary(folder) do
    with :ok <- ensure(),
         {:ok, filename} <- note_filename(title),
         {:ok, parent} <- safe_directory_path(folder),
         true <- File.dir?(parent) || {:error, :folder_not_found},
         target = Path.join(parent, filename),
         true <- FileManager.within?(target, dir()) || {:error, :invalid_path},
         :ok <- exclusive_write(target, "") do
      relative = Path.relative_to(target, dir())
      result = get(relative)
      broadcast({:created, relative})
      {:ok, result}
    else
      {:error, :eexist} -> {:error, :exists}
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_path}
    end
  end

  def create(_title, _folder), do: {:error, :blank}

  @doc "Create a folder beneath the Notes vault."
  def create_folder(path) when is_binary(path) do
    with :ok <- ensure(),
         {:ok, target} <- safe_directory_path(path),
         true <- not File.exists?(target) || {:error, :exists},
         :ok <- File.mkdir_p(target) do
      broadcast({:folder_created, normalize_relative(path)})
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :exists}
    end
  end

  def create_folder(_path), do: {:error, :invalid_path}

  @doc """
  Save a note when its on-disk revision still matches `expected_revision`.

  Returns `{:error, {:conflict, current_note}}` without writing when another
  editor changed the file. Pass `:force` only after explicit user confirmation.
  """
  def save(path, body, expected_revision) when is_binary(body) do
    with :ok <- validate_size(byte_size(body)),
         true <- String.valid?(body) || {:error, :binary},
         current when is_map(current) <- get(path),
         :ok <- revision_matches(current, expected_revision),
         {:ok, absolute} <- safe_note_path(path),
         :ok <- atomic_write(absolute, body) do
      saved = note(path, body, absolute)
      broadcast({:saved, saved.path, saved.revision})
      {:ok, saved}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      false -> {:error, :binary}
    end
  end

  def save(_path, _body, _revision), do: {:error, :invalid_body}

  @doc "Rename a note, keeping it in its current folder."
  def rename(path, new_title) when is_binary(path) and is_binary(new_title) do
    with {:ok, filename} <- note_filename(new_title) do
      relocate(path, join_relative(folder_of(path), filename))
    end
  end

  def rename(_path, _new_title), do: {:error, :blank}

  @doc "Move a note into another folder beneath the vault."
  def move(path, folder) when is_binary(path) and is_binary(folder) do
    relocate(path, join_relative(normalize_folder(folder), Path.basename(path)))
  end

  def move(_path, _folder), do: {:error, :invalid_path}

  @doc "Permanently delete one note."
  def delete(path) do
    with {:ok, absolute} <- safe_note_path(path),
         {:ok, %File.Stat{type: :regular}} <- File.stat(absolute),
         :ok <- File.rm(absolute) do
      broadcast({:deleted, normalize_relative(path)})
      :ok
    else
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_a_file}
    end
  end

  defp walk(absolute_dir, relative_dir) do
    absolute_dir
    |> entries()
    |> Enum.flat_map(fn {entry, absolute, stat} ->
      relative = join_relative(relative_dir, entry)

      case stat do
        %File.Stat{type: :directory} -> walk(absolute, relative)
        %File.Stat{type: :regular} -> maybe_summary(relative, absolute, stat)
        _ -> []
      end
    end)
  end

  defp walk_folders(absolute_dir, relative_dir) do
    absolute_dir
    |> entries()
    |> Enum.flat_map(fn {entry, absolute, stat} ->
      relative = join_relative(relative_dir, entry)

      case stat do
        %File.Stat{type: :directory} -> [relative | walk_folders(absolute, relative)]
        _ -> []
      end
    end)
  end

  # One `lstat` per entry, feeding both walks. Dot-entries are skipped: they are
  # either another tool's bookkeeping or one of this module's own in-flight
  # temporary files, and neither is a note. Anything that resolves outside the
  # vault (a planted symlink) is dropped here rather than deeper in.
  defp entries(absolute_dir) do
    case File.ls(absolute_dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.flat_map(&entry(absolute_dir, &1))

      {:error, _reason} ->
        []
    end
  end

  defp entry(absolute_dir, entry) do
    absolute = Path.join(absolute_dir, entry)

    with {:ok, stat} <- File.lstat(absolute, time: :posix),
         true <- FileManager.within?(absolute, dir()) do
      [{entry, absolute, stat}]
    else
      _ -> []
    end
  end

  defp maybe_summary(relative, _absolute, stat) do
    if markdown_path?(relative), do: [summary(relative, stat)], else: []
  end

  defp summary(path, %File.Stat{size: size, mtime: seconds}) do
    %{
      id: dom_id(path),
      path: normalize_relative(path),
      title: path |> Path.basename() |> Path.rootname(),
      updated_at: DateTime.from_unix!(seconds),
      size: size,
      supported: size <= @max_body_bytes
    }
  end

  defp note(path, body, absolute) do
    path
    |> normalize_relative()
    |> summary(stat(absolute))
    |> Map.merge(%{body: body, revision: revision(body)})
  end

  defp stat(absolute) do
    case File.stat(absolute, time: :posix) do
      {:ok, stat} -> stat
      _ -> %File.Stat{size: 0, mtime: 0}
    end
  end

  # Foldered notes first, then loose ones, alphabetically inside each group.
  defp sort_key(%{path: path}) do
    folder = folder_of(path)
    {if(folder == "", do: 1, else: 0), String.downcase(path)}
  end

  # Copy-then-remove rather than `File.rename/2`: rename silently clobbers an
  # existing destination, and losing a note to a name collision is the failure
  # this vault is built to avoid. The exclusive write refuses the collision, and
  # a crash between the two steps leaves a duplicate — recoverable — never a hole.
  defp relocate(from, to) do
    with {:ok, source} <- safe_note_path(from),
         {:ok, destination} <- safe_note_path(to),
         :ok <- distinct(source, destination),
         true <- File.dir?(Path.dirname(destination)) || {:error, :folder_not_found},
         {:ok, body} <- File.read(source),
         :ok <- exclusive_write(destination, body),
         :ok <- remove_source(source, destination) do
      moved = normalize_relative(to)
      broadcast({:moved, normalize_relative(from), moved})
      {:ok, get(moved)}
    else
      :unchanged -> {:ok, get(normalize_relative(from))}
      {:error, :eexist} -> {:error, :exists}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_path}
    end
  end

  defp distinct(source, source), do: :unchanged
  defp distinct(_source, _destination), do: :ok

  defp remove_source(source, destination) do
    case File.rm(source) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(destination)
        {:error, reason}
    end
  end

  defp folder_of(path) do
    case path |> normalize_relative() |> Path.dirname() do
      "." -> ""
      folder -> folder
    end
  end

  defp normalize_folder(""), do: ""
  defp normalize_folder(folder), do: normalize_relative(folder)

  defp safe_note_path(path) do
    with {:ok, relative} <- validate_relative(path),
         true <- markdown_path?(relative) || {:error, :unsupported},
         absolute = Path.join(dir(), relative),
         true <- FileManager.within?(absolute, dir()) || {:error, :invalid_path} do
      {:ok, absolute}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_path}
    end
  end

  defp safe_directory_path("") do
    {:ok, dir()}
  end

  defp safe_directory_path(path) do
    with {:ok, relative} <- validate_relative(path),
         absolute = Path.join(dir(), relative),
         true <- FileManager.within?(absolute, dir()) || {:error, :invalid_path} do
      {:ok, absolute}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_path}
    end
  end

  defp validate_relative(path) when is_binary(path) do
    normalized = normalize_relative(path)
    parts = Path.split(normalized)

    cond do
      normalized == "" -> {:error, :blank}
      Path.type(path) == :absolute -> {:error, :invalid_path}
      String.contains?(path, ["\\", "\0"]) -> {:error, :invalid_path}
      Enum.any?(parts, &(&1 in ["", ".", ".."])) -> {:error, :invalid_path}
      true -> {:ok, normalized}
    end
  end

  defp validate_relative(_path), do: {:error, :invalid_path}

  defp note_filename(title) do
    clean =
      title
      |> String.replace(~r/[\/\\:*?"<>|\x00-\x1f]/u, "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.trim_leading(".")
      |> String.slice(0, @max_title_length)
      |> String.trim()

    cond do
      clean == "" -> {:error, :blank}
      markdown_path?(clean) -> {:ok, clean}
      true -> {:ok, clean <> ".md"}
    end
  end

  defp markdown_path?(path) do
    String.downcase(Path.extname(path)) in @extensions
  end

  defp validate_size(size) when size <= @max_body_bytes, do: :ok
  defp validate_size(_size), do: {:error, :too_large}

  defp revision_matches(_current, :force), do: :ok

  defp revision_matches(%{revision: revision}, revision) when is_binary(revision), do: :ok

  defp revision_matches(current, _expected), do: {:error, {:conflict, current}}

  defp exclusive_write(path, body) do
    case File.write(path, body, [:binary, :exclusive]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp atomic_write(path, body) do
    temporary =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.buster-claw-#{System.unique_integer([:positive])}.tmp"
      )

    with :ok <- exclusive_write(temporary, body),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  defp revision(body) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end

  defp dom_id(path), do: "note-" <> Base.url_encode64(path, padding: false)

  defp normalize_relative(path) do
    path
    |> to_string()
    |> Path.split()
    |> Path.join()
  end

  defp join_relative("", entry), do: entry
  defp join_relative(relative, entry), do: Path.join(relative, entry)

  defp broadcast(event), do: Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:notes, event})
end
