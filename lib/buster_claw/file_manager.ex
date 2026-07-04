defmodule BusterClaw.FileManager do
  @moduledoc """
  Secure, lazy filesystem operations backing the in-app file manager.

  Every read and mutation takes an allowed `base` root and is validated with
  `within?/2` (paths are `Path.expand`'d, traversal/escape rejected) so an
  operation can never act outside the base. This is a local single-user app —
  the bar is "never act outside the active base," not full sandboxing.

  Listing is one level deep (children are fetched on demand as the tree
  expands), keeping it cheap for large trees.
  """

  @max_preview_bytes 1_000_000

  @doc "Immediate children of `dir`, dirs first then case-insensitive alpha."
  def list(dir, base) do
    with {:ok, abs} <- ensure_within(dir, base) do
      cond do
        not File.dir?(abs) ->
          {:error, :not_a_directory}

        true ->
          case File.ls(abs) do
            {:ok, names} ->
              entries =
                names
                |> Enum.map(&entry(Path.join(abs, &1)))
                |> Enum.reject(&is_nil/1)
                |> Enum.sort_by(&{sort_rank(&1.type), String.downcase(&1.name)})

              {:ok, entries}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  @doc "Read a text file for preview. Caps size and rejects binary content."
  def read_file(path, base) do
    with {:ok, abs} <- ensure_within(path, base) do
      case File.stat(abs) do
        {:ok, %File.Stat{type: :regular, size: size}} when size > @max_preview_bytes ->
          {:error, :too_large}

        {:ok, %File.Stat{type: :regular}} ->
          case File.read(abs) do
            {:ok, content} ->
              if String.valid?(content), do: {:ok, content}, else: {:error, :binary}

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, _stat} ->
          {:error, :not_a_file}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Create a new directory `name` inside `parent`."
  def create_dir(parent, name, base) do
    with :ok <- validate_name(name),
         {:ok, parent_abs} <- ensure_within(parent, base),
         {:ok, target} <- ensure_within(Path.join(parent_abs, name), base) do
      if File.exists?(target) do
        {:error, :already_exists}
      else
        case File.mkdir_p(target) do
          :ok -> {:ok, target}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc "Create a new empty file `name` inside `parent`."
  def create_file(parent, name, base) do
    with :ok <- validate_name(name),
         {:ok, parent_abs} <- ensure_within(parent, base),
         {:ok, target} <- ensure_within(Path.join(parent_abs, name), base) do
      if File.exists?(target) do
        {:error, :already_exists}
      else
        case File.write(target, "") do
          :ok -> {:ok, target}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc "Rename the entry at `path` to `new_name` (same directory)."
  def rename(path, new_name, base) do
    with :ok <- validate_name(new_name),
         {:ok, abs} <- ensure_within(path, base),
         {:ok, dest} <- ensure_within(Path.join(Path.dirname(abs), new_name), base) do
      cond do
        dest == abs -> {:ok, abs}
        File.exists?(dest) -> {:error, :already_exists}
        true -> do_rename(abs, dest)
      end
    end
  end

  @doc "Move the entry at `path` into the directory `dest_dir`."
  def move(path, dest_dir, base) do
    with {:ok, abs} <- ensure_within(path, base),
         {:ok, dest_abs} <- ensure_within(dest_dir, base),
         {:ok, target} <- ensure_within(Path.join(dest_abs, Path.basename(abs)), base) do
      cond do
        not File.dir?(dest_abs) -> {:error, :not_a_directory}
        target == abs -> {:ok, abs}
        File.exists?(target) -> {:error, :already_exists}
        true -> do_rename(abs, target)
      end
    end
  end

  @doc "Delete the entry at `path` (recursively for directories)."
  def delete(path, base) do
    with {:ok, abs} <- ensure_within(path, base) do
      if abs == Path.expand(base) do
        {:error, :cannot_delete_base}
      else
        case File.rm_rf(abs) do
          {:ok, _removed} -> :ok
          {:error, reason, _file} -> {:error, reason}
        end
      end
    end
  end

  @doc "The current user's home directory — the broad base used to relocate the workspace."
  def home, do: System.user_home() || "/"

  @doc "Whether `path` is the same as or nested under `base`."
  def within?(path, base) do
    base = canonical(base)
    path = canonical(path)
    path == base or String.starts_with?(path, base <> "/")
  end

  # Canonicalize by resolving symlinks along the path (one hop per component,
  # over the parts that exist), so a symlink *inside* `base` that points outside
  # it can't slip past the lexical containment check. Non-existent tail
  # components (e.g. a create target) are kept as-is. This is a guard, not a full
  # `realpath` — it defeats a planted-symlink escape without heavier machinery.
  defp canonical(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", fn part, acc ->
      joined = Path.join(acc, part)

      case File.read_link(joined) do
        {:ok, target} -> Path.expand(target, acc)
        _ -> joined
      end
    end)
  end

  # --- internals ----------------------------------------------------------

  defp do_rename(from, to) do
    case File.rename(from, to) do
      :ok -> {:ok, to}
      {:error, reason} -> {:error, reason}
    end
  end

  defp entry(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: type, size: size, mtime: mtime}} ->
        %{
          name: Path.basename(path),
          path: path,
          type: if(type == :directory, do: :dir, else: :file),
          size: size,
          mtime: mtime
        }

      {:error, _reason} ->
        nil
    end
  end

  defp sort_rank(:dir), do: 0
  defp sort_rank(_), do: 1

  defp ensure_within(path, base) do
    abs = Path.expand(path)
    if within?(abs, base), do: {:ok, abs}, else: {:error, :outside_base}
  end

  defp validate_name(name) do
    cond do
      not is_binary(name) -> {:error, :invalid_name}
      String.trim(name) == "" -> {:error, :invalid_name}
      String.contains?(name, ["/", "\\"]) -> {:error, :invalid_name}
      name in [".", ".."] -> {:error, :invalid_name}
      true -> :ok
    end
  end
end
