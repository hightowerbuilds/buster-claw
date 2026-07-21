defmodule BusterClaw.Notes do
  @moduledoc """
  A small Obsidian-style note surface: plain markdown files under
  `<workspace>/notes/`, one file per note.

  The filename (without the `.md` extension) *is* the note's title, so notes stay
  human-readable and `grep`-able on disk with no database, frontmatter, or
  lock-in — the same "everything is markdown you own" posture as the rest of the
  workspace. Rendering to HTML for the reading view goes through
  `BusterClaw.Markdown` (sanitized, since workspace files can be agent-authored).

  ## Safety

  A note's `name` is the only user-controlled path segment. `create/1` sanitizes
  it to a single filesystem-safe path component (no separators, no leading dots,
  bounded length); every lookup re-validates via `safe_path/1`, which rejects
  separators/`..` and confirms the resolved path stays under `dir/0`
  (`FileManager.within?/2`). There is no way to address a file outside the notes
  directory.
  """

  alias BusterClaw.FileManager
  alias BusterClaw.Library.Artifact

  @extension ".md"
  @max_name 120

  @doc "Absolute path to the workspace notes directory."
  def dir, do: Artifact.workspace_path("notes")

  @doc "Create the notes directory if it doesn't exist (best-effort)."
  def ensure do
    File.mkdir_p(dir())
    :ok
  end

  @doc """
  List notes as `%{name: String.t(), updated_at: DateTime.t()}`, newest first.
  Bodies are not loaded here — call `get/1` for content.
  """
  def list do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(Path.extname(&1) == @extension))
        |> Enum.map(&summary(Path.rootname(&1, @extension)))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

      {:error, _} ->
        []
    end
  end

  @doc "Read one note by name. Returns the note map or `nil` if it doesn't exist."
  def get(name) do
    with {:ok, path} <- safe_path(name),
         {:ok, body} <- File.read(path) do
      %{name: name, body: body, updated_at: mtime(path)}
    else
      _ -> nil
    end
  end

  @doc "Whether a note with this name exists."
  def exists?(name) do
    match?({:ok, path} when is_binary(path), safe_path(name)) and
      File.regular?(elem(safe_path(name), 1))
  end

  @doc """
  Create a new, empty note from a title. Returns `{:ok, name}` with the sanitized
  name, or `{:error, :blank}` / `{:error, :exists}`.
  """
  def create(title) when is_binary(title) do
    ensure()

    case sanitize(title) do
      "" ->
        {:error, :blank}

      name ->
        {:ok, path} = safe_path(name)

        if File.exists?(path) do
          {:error, :exists}
        else
          File.write!(path, "")
          {:ok, name}
        end
    end
  end

  def create(_), do: {:error, :blank}

  @doc """
  Write `body` to an existing note. Returns `{:ok, note}` or `{:error, reason}`.
  Autosave from the editor lands here; the note must already exist (created via
  `create/1`), so a stray save can't mint files at arbitrary names.
  """
  def save(name, body) when is_binary(body) do
    with {:ok, path} <- safe_path(name),
         true <- File.regular?(path) do
      File.write!(path, body)
      {:ok, %{name: name, body: body, updated_at: mtime(path)}}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :not_found}
    end
  end

  @doc "Delete a note by name. Idempotent — a missing note is still `:ok`."
  def delete(name) do
    case safe_path(name) do
      {:ok, path} ->
        File.rm(path)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- internals ---

  defp summary(name) do
    case safe_path(name) do
      {:ok, path} -> %{name: name, updated_at: mtime(path)}
      _ -> nil
    end
  end

  # Collapse a free-text title into a single filesystem-safe path component:
  # drop separators, control chars, and the characters Windows/macOS reject in
  # filenames; squeeze whitespace; strip leading dots (no hidden/`.`/`..` files);
  # bound the length. The result is the note's on-disk name AND its display title.
  defp sanitize(title) do
    title
    |> String.replace(~r/[\/\\:*?"<>|\x00-\x1f]/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.trim_leading(".")
    |> String.trim()
    |> String.slice(0, @max_name)
    |> String.trim()
  end

  # Resolve a name to its absolute path, rejecting anything that could escape the
  # notes directory. `name` must be a single component (no separators, no `..`),
  # and the joined path must stay under `dir/0`.
  defp safe_path(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> {:error, :blank}
      String.contains?(trimmed, ["/", "\\", "\0"]) -> {:error, :invalid}
      trimmed in [".", ".."] -> {:error, :invalid}
      true -> confirm_within(Path.join(dir(), trimmed <> @extension))
    end
  end

  defp safe_path(_), do: {:error, :invalid}

  defp confirm_within(path) do
    if FileManager.within?(path, dir()), do: {:ok, path}, else: {:error, :invalid}
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: seconds}} -> DateTime.from_unix!(seconds)
      _ -> DateTime.from_unix!(0)
    end
  end
end
