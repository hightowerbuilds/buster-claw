defmodule BusterClaw.Music do
  @moduledoc """
  The music library — audio files in `<workspace>/music/` that the user owns,
  uploaded through the Music tab and played by the dock player.

  This is `BusterClaw.Notifications.Sound` at a larger size class, and it
  deliberately copies that module's shape: a directory in the DataZone,
  membership in `list/0` as the only path allowlist, and content types resolved
  from the extension. Nothing here reaches the network and nothing is bundled —
  the library is whatever the user put on their own disk.

  ## Why it is not just `Notifications.Sound`

  Different lifecycle and different size class. A notification chime is one
  second, chosen once, and routed per event; a track is five minutes, browsed
  among hundreds, and queued. Sharing one module would mean a sound-map
  concept in the music library and a queue concept in the chime library. If
  real duplication emerges later, extract a helper then — not before.

  ## Metadata is derived from the filename, on purpose

  There is no ID3 parsing here (see MUSIC_ROADMAP Part III). `Artist - Title.mp3`
  splits into two fields; anything else displays as its own filename. That is
  honest, costs nothing, and cannot mis-parse a tag. If filenames turn out to
  read badly in the tab, ID3 becomes a real decision with a real reason behind
  it rather than a reflex.

  ## Path safety

  `path_for/1` resolves only names that `list/0` reports as real directory
  entries, so request input is never joined into a path — the same posture as
  `Sound.path_for/1`. A name containing a separator or `..` can never appear in
  `list/0` (it holds basenames of actual files), so traversal has no surface
  here rather than being filtered out downstream.
  """

  require Logger

  alias BusterClaw.Library.Artifact

  @subdir "music"

  # FLAC joins the Sound list because people who keep music files keep FLACs.
  # Whether the webview will actually PLAY each of these is a separate question
  # answered by probing the packaged app (MUSIC_ROADMAP Risk 2) — an accepted
  # format that won't play is worse than a rejected one, so this list is
  # expected to shrink if the probe says so.
  @exts ~w(.mp3 .m4a .aac .wav .ogg .flac)

  @content_types %{
    ".mp3" => "audio/mpeg",
    ".m4a" => "audio/mp4",
    ".aac" => "audio/aac",
    ".wav" => "audio/wav",
    ".ogg" => "audio/ogg",
    ".flac" => "audio/flac"
  }

  @default_content_type "application/octet-stream"

  # The separator that splits a filename into artist and title. ASCII
  # hyphen-with-spaces only: it is what file naming conventions actually use,
  # and a bare "-" would mangle "Blink-182.mp3".
  @artist_separator " - "

  @doc "Absolute path to the `music/` folder in the active workspace."
  def dir, do: Artifact.workspace_path(@subdir)

  @doc "Audio file extensions the library accepts."
  def accepted_extensions, do: @exts

  @doc """
  The audio content-type for a path or basename. Unknown extensions get
  `application/octet-stream` rather than a guess — a wrong audio type is worse
  than an honest binary one, because the element will try to decode it.
  """
  def content_type(name) when is_binary(name) do
    Map.get(@content_types, name |> Path.extname() |> String.downcase(), @default_content_type)
  end

  @doc """
  Sorted basenames of every audio file in the library.

  Sorted case-insensitively, which is where this departs from `Sound.list/0`:
  that library holds a handful of files, this one is browsed, and a plain
  `Enum.sort/1` files every capitalized artist above every lowercase one.
  """
  def list do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&audio_file?/1)
        |> Enum.sort_by(&String.downcase/1)

      _ ->
        []
    end
  end

  @doc """
  Every track in the library as a `track_info/1` map, in `list/0` order.
  """
  def tracks, do: Enum.map(list(), &track_info/1)

  @doc """
  Filename-derived metadata for a library track. `"Miles Davis - So What.mp3"`
  yields artist `"Miles Davis"` and title `"So What"`.

  `artist` is `nil` when the name carries no `" - "`, and `title` is then the
  whole filename without its extension. `size_bytes` is `nil` when the file is
  gone — the listing is a snapshot of a directory the user can edit in Finder
  at any moment, so a track that vanished between `list/0` and here is an
  ordinary event, not an error.
  """
  def track_info(name) when is_binary(name) do
    stem = Path.rootname(name)

    {artist, title} =
      case String.split(stem, @artist_separator, parts: 2) do
        [artist, title] -> {String.trim(artist), String.trim(title)}
        _ -> {nil, stem}
      end

    %{
      name: name,
      artist: presence(artist),
      title: presence(title) || name,
      extension: name |> Path.extname() |> String.downcase(),
      content_type: content_type(name),
      size_bytes: size_of(name)
    }
  end

  @doc """
  Absolute path for a library track by basename, or `nil` when the name isn't in
  the library. Membership in `list/0` is the allowlist — see the moduledoc.
  """
  def path_for(name) when is_binary(name) do
    if name in list(), do: Path.join(dir(), name)
  end

  def path_for(_), do: nil

  @doc "Remove a track from the library."
  def delete(name) when is_binary(name) do
    case path_for(name) do
      nil -> {:error, :not_found}
      path -> File.rm(path)
    end
  end

  def delete(_), do: {:error, :not_found}

  @doc "True when the library holds at least one playable file."
  def any?, do: list() != []

  @doc """
  Total bytes held by the library. The DataZone is the user's own disk and music
  is the largest thing anyone will put in it, so the tab shows this rather than
  imposing a quota (MUSIC_ROADMAP Risk 5).
  """
  def total_bytes do
    list()
    |> Enum.map(&(size_of(&1) || 0))
    |> Enum.sum()
  end

  @doc """
  Create the `music/` folder and a README explaining how music gets here, so the
  feature is discoverable from the filesystem and not only from the UI.
  Best-effort — never raises. No audio is bundled; the library is the user's.
  """
  def ensure do
    File.mkdir_p(dir())
    readme = Path.join(dir(), "README.md")
    unless File.exists?(readme), do: File.write(readme, readme_body())
    :ok
  rescue
    error ->
      Logger.warning("Music.ensure failed: #{Exception.message(error)}")
      :ok
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp audio_file?(name) do
    String.downcase(Path.extname(name)) in @exts and File.regular?(Path.join(dir(), name))
  end

  defp size_of(name) do
    case File.stat(Path.join(dir(), name)) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> nil
    end
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: value

  defp readme_body do
    """
    # Music

    Audio files here are your music library, managed from the Music tab on the
    home page. Drop files in this folder directly and they show up too — this is
    your disk, not a database.

    - Accepted: `.mp3`, `.m4a`, `.aac`, `.wav`, `.ogg`, `.flac`.
    - Name files `Artist - Title.mp3` and the library splits them into two
      columns. Any other name displays as-is.
    - Nothing here is uploaded anywhere. Buster Claw plays these files from this
      folder on this machine.
    """
  end
end
