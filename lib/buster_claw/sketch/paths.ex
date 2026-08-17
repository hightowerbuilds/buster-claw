defmodule BusterClaw.Sketch.Paths do
  @moduledoc """
  Where a sketch and its images live on disk, and what counts as a name.

  Extracted so the dependency runs one way: `Store` → `Assets` → `Paths`.

  It did not, briefly. `Store.delete/1` removes a sketch's sidecar (that is the
  whole argument for `D11` — the images go with the document), and `Assets`
  needed the sketch's path to know where the sidecar was, so the two called each
  other and `check_cycles.sh` caught a third cycle in a repo that accepts two.
  Duplicating the name rule in both would have broken the cycle and been worse:
  two allowlists that must agree, in the one place where disagreeing means a
  path escapes.

  ## The name rule is an allowlist, not a sanitiser

  A sketch name is a bare filename. Nothing containing a separator or a `..`
  matches, so there is nothing to strip — the same posture Pockets takes, and for
  the same reason: a rewritten path is a path someone chose that we then changed,
  and the interesting cases are the ones where they meant it.
  """

  alias BusterClaw.Library.Artifact

  @dir "sketches"
  @ext ".json"
  @assets_suffix ".assets"
  @name_re ~r/\A[a-zA-Z0-9][a-zA-Z0-9 _-]{0,63}\z/
  @asset_re ~r/\A[0-9a-f]{16}\.(png|jpg|gif|webp)\z/

  @doc "The directory sketches live in."
  def dir, do: Artifact.workspace_path([@dir])

  @doc "The document's extension."
  def extension, do: @ext

  @doc "Whether `name` is a usable sketch name."
  def valid_name?(name) when is_binary(name) do
    Regex.match?(@name_re, name) and not String.contains?(name, ["/", "\\", ".."])
  end

  def valid_name?(_name), do: false

  @doc "Whether `file` is an asset filename this app minted."
  def valid_asset?(file) when is_binary(file), do: Regex.match?(@asset_re, file)
  def valid_asset?(_file), do: false

  @doc "Absolute path to a sketch document. `{:ok, path}` or `{:error, :invalid_name}`."
  def document(name) do
    if valid_name?(name), do: {:ok, Path.join(dir(), name <> @ext)}, else: {:error, :invalid_name}
  end

  @doc "Absolute path to a sketch's sidecar directory."
  def assets_dir(name) do
    with {:ok, path} <- document(name), do: {:ok, Path.rootname(path) <> @assets_suffix}
  end

  @doc "Absolute path to one asset inside a sketch's sidecar."
  def asset(name, file) do
    with true <- valid_asset?(file),
         {:ok, dir} <- assets_dir(name) do
      {:ok, Path.join(dir, file)}
    else
      false -> {:error, :invalid_name}
      error -> error
    end
  end
end
