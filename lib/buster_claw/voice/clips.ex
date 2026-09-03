defmodule BusterClaw.Voice.Clips do
  @moduledoc """
  Say anything: a line the operator typed, rendered in their voice, kept.

  This is the third of the three things the recorder makes possible — record a
  clip, it becomes the reference, now type something and hear yourself say it.
  It is also the fastest way to *judge* a reference clip: the chimes take
  forty minutes to re-make, a single sentence takes a few.

  ## Rendering is the cache's job; this only remembers

  A clip is `Renderer.render/2` with the operator's engine settings merged in,
  exactly like a chime. The cache names files by content hash, which is right
  for the cache and useless for a person, so this keeps a small manifest beside
  it — the text, when it was made, and which cache file it landed in. A clip
  whose file has since vanished is dropped from the listing rather than shown
  with a dead player.

  ## Forgetting a clip does not delete its audio

  The cache file may be shared: type "Your timer is up." and the clip IS the
  timer chime. `forget/1` drops the manifest row and leaves the file to the
  cache, which owns it.
  """

  alias BusterClaw.Voice.Config
  alias BusterClaw.Voice.Renderer

  @manifest "clips.json"

  @doc """
  Render `text` in the operator's voice. `{:ok, path}` when it was already made
  (and it is recorded now), `{:queued, key}` when it went to the queue — the
  caller records it when the render lands, via `record/2`.
  """
  @spec make(String.t(), keyword()) ::
          {:ok, String.t()} | {:queued, String.t()} | {:error, term()}
  def make(text, opts \\ []) when is_binary(text) do
    text = String.trim(text)

    case Renderer.render(text, with_config(opts)) do
      {:ok, path} = ok ->
        record(text, path)
        ok

      other ->
        other
    end
  end

  @doc "Remember that `text` rendered to `path`. Newest first; the same text twice is one row."
  @spec record(String.t(), String.t()) :: :ok
  def record(text, path) when is_binary(text) and is_binary(path) do
    text = String.trim(text)
    rest = Enum.reject(read(), &(&1["text"] == text))
    row = %{"text" => text, "path" => path, "at" => DateTime.utc_now() |> DateTime.to_iso8601()}
    write([row | rest])
  end

  @doc "Every clip whose audio still exists, newest first."
  @spec list() :: [%{text: String.t(), path: String.t(), name: String.t(), at: String.t()}]
  def list do
    read()
    |> Enum.filter(&File.regular?(&1["path"]))
    |> Enum.map(fn row ->
      %{text: row["text"], path: row["path"], name: Path.basename(row["path"]), at: row["at"]}
    end)
  end

  @doc "Drop a clip from the listing. The cache keeps the file."
  @spec forget(String.t()) :: :ok
  def forget(path) when is_binary(path) do
    write(Enum.reject(read(), &(&1["path"] == path)))
  end

  @doc """
  A clip's cache path from its basename, or `nil` — allowlist over the manifest.
  """
  @spec resolve(String.t()) :: String.t() | nil
  def resolve(name) when is_binary(name) do
    Enum.find_value(list(), fn clip -> if clip.name == name, do: clip.path end)
  end

  defp with_config(opts), do: Keyword.merge(Config.render_opts(), opts)

  defp manifest_path, do: Path.join(Renderer.cache_dir(), @manifest)

  defp read do
    with {:ok, json} <- File.read(manifest_path()),
         {:ok, rows} when is_list(rows) <- Jason.decode(json) do
      Enum.filter(rows, &(is_map(&1) and is_binary(&1["text"]) and is_binary(&1["path"])))
    else
      _ -> []
    end
  end

  defp write(rows) do
    File.mkdir_p(Renderer.cache_dir())
    File.write(manifest_path(), Jason.encode!(rows))
  end
end
