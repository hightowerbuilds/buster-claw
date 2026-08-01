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

  # Nested under `sounds/` — one audio folder in the workspace, not three.
  @subdir Path.join("sounds", "music")

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

  # Characters a stored filename may keep; everything else becomes "-". See
  # `safe_name/1` for why this is wider than Sound's equivalent.
  @name_allowed ~r/[^\p{L}\p{N} .,\-_()\[\]&'!+#@]/u

  # Leaves room under the common 255-byte filename limit for an extension and a
  # "-999" collision suffix.
  @max_stem_bytes 180

  # Leading bytes that identify a container we accept. Checked to *accept*, not
  # to reject — see `plausible_audio?/1`.
  @audio_magic [
    "ID3",
    "RIFF",
    "fLaC",
    "OggS"
  ]

  # Leading bytes that identify something that is definitely not audio. `<` is
  # the one that matters: a file whose name says .mp3 and whose content is HTML
  # is the shape of a stored-XSS attempt, and the library is a folder an agent
  # can write to.
  @not_audio_magic [
    "%PDF",
    "\x89PNG",
    "\xFF\xD8\xFF",
    "GIF8",
    "PK\x03\x04",
    "\x7FELF",
    "MZ",
    "<",
    "{",
    "#!"
  ]

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

  # ---------------------------------------------------------------------------
  # Ingest
  # ---------------------------------------------------------------------------

  @doc """
  Store an uploaded file in the library, returning the basename it landed under.

  `source_path` is a temp file (a LiveView upload's `:path`); `client_name` is
  the untrusted name the browser reported. Nothing about `client_name` is
  trusted except its extension, and even that is only used to *reject*.

      {:ok, "Miles Davis - So What.mp3"} = store("/tmp/live_view_upload", "So What.mp3")

  Errors: `:unsupported_format` (extension not in `accepted_extensions/0`),
  `:not_audio` (the bytes disagree with the name), `:enoent` (no readable source),
  or any `File.cp/2` posix reason.
  """
  def store(source_path, client_name) when is_binary(source_path) and is_binary(client_name) do
    ext = client_name |> Path.extname() |> String.downcase()

    cond do
      ext not in @exts ->
        {:error, :unsupported_format}

      not File.regular?(source_path) ->
        {:error, :enoent}

      not plausible_audio?(source_path) ->
        {:error, :not_audio}

      true ->
        File.mkdir_p(dir())
        name = available_name(safe_name(client_name))

        case File.cp(source_path, Path.join(dir(), name)) do
          :ok -> {:ok, name}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def store(_source, _name), do: {:error, :unsupported_format}

  @doc """
  The basename an uploaded file will be stored under, before collision handling.

  `Path.basename/1` first, so a name carrying directories (`../../etc/x.mp3`)
  reduces to its last segment before anything else looks at it. Then everything
  outside `@name_allowed` becomes `-`, runs of whitespace collapse, and leading
  dots go so an upload cannot create a dotfile.

  Deliberately **more permissive than `Sound`'s sanitizer**, which replaces
  every non-word character including spaces. That is fine for a chime and would
  be destructive here: `track_info/1` splits on `" - "`, so a sanitizer that
  turned spaces into dashes would turn "Miles Davis - So What.mp3" into
  "Miles-Davis---So-What.mp3" and silently destroy the naming convention this
  library is built around. Spaces, parentheses, and apostrophes are how music
  files are actually named.
  """
  def safe_name(client_name) when is_binary(client_name) do
    # The extension comes from the ORIGINAL name, which is the same place
    # `store/2` reads it for the accept check. Deriving it from a trimmed or
    # basenamed copy lets the two disagree: `"   .mp3"` trims to `".mp3"`, which
    # Elixir reads as a dotfile with NO extension, so the upload passed the
    # `.mp3` gate and then landed as a file called `track` — invisible to
    # `list/0`, a success message for a track that never appeared.
    ext = client_name |> Path.extname() |> String.downcase()

    stem =
      client_name
      |> Path.basename()
      |> strip_extension(ext)
      |> String.replace(@name_allowed, "-")
      |> String.replace(~r/\s+/u, " ")
      |> String.replace(~r/^[.\s]+/u, "")
      |> String.trim()
      |> truncate_bytes(@max_stem_bytes)
      |> String.trim()

    if stem == "", do: "track" <> ext, else: stem <> ext
  end

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

  # A collision-free basename: the name itself, else -2, -3, … rather than
  # overwriting a track the user already has.
  defp available_name(base) do
    ext = Path.extname(base)
    stem = Path.rootname(base)

    numbered = Stream.map(2..999, fn n -> "#{stem}-#{n}#{ext}" end)

    # The `||` is the point: Sound's version of this returns nil once every
    # candidate is taken, and the nil then reaches Path.join and raises. A
    # thousand same-named uploads is absurd, but "absurd" is not "impossible"
    # and a crash is a bad way to find out.
    Enum.find(Stream.concat([base], numbered), &(not File.exists?(Path.join(dir(), &1)))) ||
      "#{stem}-#{System.unique_integer([:positive])}#{ext}"
  end

  # Does the content agree with the name?
  #
  # Accept-known-audio, then reject-known-other, then ACCEPT by default. The
  # default is the important half: rejecting a real music file the user owns is
  # a much worse outcome than storing a file that turns out not to play, so an
  # unrecognized header is not treated as evidence of anything. What this does
  # catch is the clear-cut case — a PDF or an HTML document wearing a .mp3
  # extension — which is both the acceptance criterion and the shape that
  # matters for a folder an agent can write into.
  defp plausible_audio?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 12)) do
      {:ok, head} when is_binary(head) -> classify_head(head)
      # Unreadable or empty: let the copy decide, don't guess from nothing.
      _ -> true
    end
  end

  defp classify_head(head) do
    cond do
      Enum.any?(@audio_magic, &String.starts_with?(head, &1)) -> true
      # MPEG frame sync (a bare MP3 with no ID3 tag, or ADTS AAC). The sync word
      # needs the second byte's top three bits set, and every byte >= 0xE0 has
      # exactly that — so this is the band(x, 0xE0) == 0xE0 test without needing
      # Bitwise in a guard.
      match?(<<0xFF, second, _::binary>> when second >= 0xE0, head) -> true
      # MP4/M4A: the ftyp box sits at offset 4, not 0.
      match?(<<_::binary-size(4), "ftyp", _::binary>>, head) -> true
      Enum.any?(@not_audio_magic, &String.starts_with?(head, &1)) -> false
      true -> true
    end
  end

  # Remove the extension `store/2` validated, matched case-insensitively so
  # "SHOUT.MP3" keeps its stem. Byte arithmetic is safe here because an
  # extension in `@exts` is ASCII, so trimming its bytes off the end cannot
  # split a multi-byte character in the stem.
  defp strip_extension(base, ""), do: base

  defp strip_extension(base, ext) do
    if String.ends_with?(String.downcase(base), ext) do
      binary_part(base, 0, byte_size(base) - byte_size(ext))
    else
      base
    end
  end

  # Truncate to a byte budget without splitting a grapheme — a filename is
  # bytes to the filesystem but characters to a person.
  defp truncate_bytes(string, max) when byte_size(string) <= max, do: string

  defp truncate_bytes(string, max) do
    string
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {acc, size} ->
      next = size + byte_size(grapheme)
      if next > max, do: {:halt, {acc, size}}, else: {:cont, {[grapheme | acc], next}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

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
