defmodule BusterClaw.Sketch.Assets do
  @moduledoc """
  The images a sketch is made of: `<workspace>/sketches/<name>.assets/<hash>.<ext>`.

  `SKETCH_ROADMAP` `D11`. A sidecar beside the document rather than a shared
  library, so a sketch and its images travel together — delete the sketch and its
  images go with it, and the folder is legible in Finder next to the `.json` it
  belongs to. The cost is a duplicate when two sketches use the same picture,
  which is the cheaper mistake: the shared-folder alternative needs an orphan
  sweeper nobody has written and quietly leaves files behind on every delete.

  ## Content-named, which is the dedupe

  The filename is a hash of the bytes, so pasting the same screenshot twice
  writes one file and produces two elements pointing at it. Nothing has to track
  references, and nothing can end up with a stale name.

  ## Identified before it is written, never after

  Every entry point runs `ImageInfo` first. A file is refused before a byte lands
  in the workspace, because the alternative is writing an unknown thing into a
  folder that a route serves back over HTTP. The extension comes from what the
  bytes *are*, not from what the file was called — a `.png` that is really a JPEG
  is stored as `.jpg` and served as `image/jpeg`.
  """

  require Logger

  alias BusterClaw.Sketch.{ImageInfo, Paths}

  @max_bytes 10 * 1024 * 1024

  @doc "The sidecar directory for a sketch."
  defdelegate dir(sketch), to: Paths, as: :assets_dir

  @doc "The byte ceiling for one image."
  def max_bytes, do: @max_bytes

  @doc """
  Store bytes as an asset of `sketch`.

  Returns `{:ok, %{source, width, height, format}}` — `source` is the bare
  filename an `:image` element records.
  """
  def put_binary(sketch, binary) when is_binary(binary) do
    with :ok <- check_size(byte_size(binary)),
         {:ok, info} <- ImageInfo.inspect_binary(binary),
         {:ok, dir} <- dir(sketch),
         {:ok, name} <- write(dir, binary, info) do
      {:ok, Map.merge(info, %{source: name})}
    end
  end

  def put_binary(_sketch, _binary), do: {:error, :not_binary}

  @doc """
  Store a file already on disk as an asset of `sketch` — the packaged app's
  native-drop path, where the browser never sees the bytes.

  The header is read and validated before the file is read whole, so an enormous
  or hostile file is refused having cost only its first block.
  """
  def put_file(sketch, path) when is_binary(path) do
    with {:ok, size} <- regular_size(path),
         :ok <- check_size(size),
         {:ok, _info} <- ImageInfo.inspect_file(path),
         {:ok, binary} <- read(path) do
      put_binary(sketch, binary)
    end
  end

  def put_file(_sketch, _path), do: {:error, :invalid_path}

  @doc """
  Absolute path and media type for one asset. `{:ok, path, media_type}`.

  The name must be one this module minted — sixteen hex digits and a known
  extension. That is an allowlist rather than a traversal check: there is no
  input shaped like `../` that matches it, so nothing has to be stripped.
  """
  def resolve(sketch, file) do
    with {:ok, path} <- Paths.asset(sketch, file) do
      if File.regular?(path),
        do: {:ok, path, ImageInfo.media_type(format_of(file))},
        else: {:error, :not_found}
    end
  end

  @doc "Asset filenames belonging to a sketch."
  def list(sketch) do
    with {:ok, dir} <- dir(sketch),
         {:ok, entries} <- File.ls(dir) do
      entries |> Enum.filter(&Paths.valid_asset?/1) |> Enum.sort()
    else
      _ -> []
    end
  end

  @doc """
  Remove a sketch's whole sidecar. Called when the sketch itself is deleted —
  that is the entire argument for `D11`, so it should not be possible to delete
  one and keep the other.
  """
  def delete_all(sketch) do
    case dir(sketch) do
      {:ok, path} ->
        _ = File.rm_rf(path)
        :ok

      error ->
        error
    end
  end

  # --- internals ------------------------------------------------------------

  defp write(dir, binary, info) do
    name = hash(binary) <> ImageInfo.extension(info.format)
    path = Path.join(dir, name)

    # Same bytes, same name — already here. Content-naming makes a repeat paste
    # the dedupe rather than an error anyone has to handle.
    if File.regular?(path) do
      {:ok, name}
    else
      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(path, binary) do
        {:ok, name}
      else
        {:error, reason} ->
          Logger.warning("Sketch.Assets: cannot write #{path}: #{inspect(reason)}")
          {:error, :unwritable}
      end
    end
  end

  # 16 hex digits — 64 bits. Enough that a collision inside one sketch's folder
  # is not a thing that happens, and short enough to read in a filename.
  defp hash(binary) do
    :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp format_of(file) do
    case Path.extname(file) do
      ".png" -> :png
      ".jpg" -> :jpeg
      ".gif" -> :gif
      ".webp" -> :webp
    end
  end

  defp check_size(size) when size > @max_bytes, do: {:error, :too_large}
  defp check_size(0), do: {:error, :empty}
  defp check_size(_size), do: :ok

  # Returns the size, not the stat. Matching `%{type: :regular}` inside the `with`
  # above looked equivalent and was not: an unmatched clause makes `with` return
  # the value it failed to match, so a directory came back as `{:ok, %File.Stat{}}`
  # and every caller testing `{:ok, _}` read it as success. Narrowing what this
  # returns is what makes the failure un-representable rather than merely handled.
  defp regular_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      {:ok, %File.Stat{}} -> {:error, :not_a_file}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, _reason} -> {:error, :unreadable}
    end
  end
end
