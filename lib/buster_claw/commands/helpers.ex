defmodule BusterClaw.Commands.Helpers do
  @moduledoc """
  Generic helpers shared by `BusterClaw.Commands` and its per-domain command
  modules: safe resource fetching (translating Ecto "not found" raises into
  `{:error, :not_found}`) and workspace-path resolution for downloaded files.

  These are deliberately context-agnostic — anything tied to a specific domain
  (Google account resolution, Drive attrs, contact resources, …) lives with that
  domain, not here.
  """

  @doc """
  Fetch a resource via `apply(module, fun, [id])`, translating the canonical
  Ecto "missing" raises into `{:error, :not_found}` so callers stay on the
  `{:ok, _} | {:error, _}` contract instead of rescuing.
  """
  def safe_get(module, fun, id) do
    {:ok, apply(module, fun, [id])}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc """
  `safe_get/3` then, on success, run `fun` with the resource. A miss
  short-circuits to `{:error, :not_found}` without invoking `fun`.
  """
  def with_resource(module, getter, id, fun) do
    case safe_get(module, getter, id) do
      {:ok, resource} -> fun.(resource)
      error -> error
    end
  end

  @doc """
  Clamp a caller-supplied result limit into `1..100`, accepting integers or
  numeric strings and defaulting to 20 for anything missing or invalid. Shared
  by the search-style commands (memory, skill suggestions).
  """
  def normalize_limit(n) when is_integer(n) and n > 0, do: min(n, 100)

  def normalize_limit(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} when i > 0 -> min(i, 100)
      _ -> 20
    end
  end

  def normalize_limit(_), do: 20

  @doc "Trim a binary, returning `nil` for blank/whitespace-only values; pass other types through."
  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def blank_to_nil(value), do: value

  @doc """
  Resolve a download/save path: absolute paths are expanded as-is, relative ones
  are expanded under the workspace root.
  """
  def resolve_workspace_path(path) do
    case Path.type(path) do
      :absolute -> Path.expand(path)
      _relative -> Path.expand(path, BusterClaw.Library.Artifact.workspace_root())
    end
  end

  @doc """
  Reduce a downloaded filename to a safe basename (no path separators / traversal,
  only word chars, dot and dash), so it can't escape the downloads folder.
  """
  def sanitize_download_name(name) do
    cleaned =
      name
      |> to_string()
      |> Path.basename()
      |> String.replace(~r/[^\w.\-]+/u, "_")
      |> String.trim("_")

    case cleaned do
      "" -> "download"
      "." -> "download"
      ".." -> "download"
      other -> other
    end
  end
end
