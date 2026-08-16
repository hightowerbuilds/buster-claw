defmodule BusterClaw.Notifications.SoundStudio do
  @moduledoc """
  The editing core of the Sound Studio (SOUND_STUDIO_ROADMAP Phase 1) — read a
  WAV, cut a piece out of it, shape the edges, write it back.

  `SoundGen` proved we can *write* WAVs; this module is the half that can
  *read* one, which is what turns "here is a voicemail" into "here is a chime".
  Everything here is pure arithmetic over PCM16 with no process, no subprocess,
  and no LiveView — the same split `SoundBoard` uses, for the same reason: an
  editing operation you can only exercise through a UI is one nobody tests, and
  the boundary arithmetic below is exactly where the bugs live.

  ## The one internal format

  **PCM16, mono, 22.05 kHz** — the format `SoundGen` already writes, so a clip
  from the synthesizer and a clip cut out of a voicemail are the same kind of
  thing and can be concatenated without a conversion step. Sources arrive in
  whatever the carrier wrote; `import_source/1` is the single door that
  normalizes them, and past that door every function here is format-blind
  arithmetic.

  ## Where the subprocess lives (and where it does not)

  `import_source/1` shells out to `/usr/bin/afconvert` — a macOS *system*
  binary, present on every Mac, nothing to bundle, sign, or license — but
  **only when it has to**. A file that already parses as our internal format
  (every bundled chime, and anything the studio wrote itself) is used directly.
  The decoder is a doorman, not a dependency: no edit operation can reach it.

  ## What "normalize" does and does not do

  `normalize/2` equalizes **peaks**, not perceived loudness. A 200 ms click and
  a 1 s sustained tone normalized to the same peak do not sound equally loud —
  duration and repetition carry loudness at least as much as amplitude does.
  This is honest about being a crude instrument: it stops one sound from being
  wildly hotter than its neighbours, which is the actual problem (the bundled
  set spans 8.6 dB, found in the Phase 0 audition), and it is not a mastering
  chain.
  """

  require Logger

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Music

  # The internal format. Not configurable: the point of picking one is that
  # every operation below can assume it.
  @rate 22_050
  @channels 1
  @bits 16

  # Peak-normalize target, ~-1 dBFS. Leaves a sliver of headroom so that
  # rounding a scaled sample can never land outside int16.
  @default_target 0.891

  @decoder "/usr/bin/afconvert"

  # Ceiling on a mixdown, in ms. The mix is assembled as integer lists, so
  # length is memory; five minutes of sound effects is already generous.
  @max_mix_ms 300_000

  # The studio's own workspace folder, and what it accepts into it.
  # Nested under `sounds/` — one audio folder in the workspace, not three.
  @subdir Path.join("sounds", "studio")
  @import_exts ~w(.mp3 .m4a .aac .wav .ogg .flac)
  @content_types %{
    ".mp3" => "audio/mpeg",
    ".m4a" => "audio/mp4",
    ".aac" => "audio/aac",
    ".wav" => "audio/wav",
    ".ogg" => "audio/ogg",
    ".flac" => "audio/flac"
  }

  defstruct sample_rate: @rate, channels: @channels, bits: @bits, data: <<>>

  @type t :: %__MODULE__{
          sample_rate: pos_integer(),
          channels: pos_integer(),
          bits: pos_integer(),
          data: binary()
        }

  @doc "The internal format, as `{sample_rate, channels, bits}`."
  def internal_format, do: {@rate, @channels, @bits}

  @doc "True when a clip is already in the studio's internal format."
  def internal?(%__MODULE__{sample_rate: @rate, channels: @channels, bits: @bits}), do: true
  def internal?(%__MODULE__{}), do: false

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  @doc """
  Parse a WAV binary into a clip.

  **Walks the RIFF chunk list rather than assuming a 44-byte header.**
  `SoundGen` writes a minimal header where the data does start at byte 44, but
  `afconvert` is entitled to emit `LIST`/`fact`/padding chunks ahead of `data`,
  and a parser that seeks to a fixed offset reads metadata as audio — which
  sounds like a burst of noise at the head of every imported clip.
  """
  def parse(binary) when is_binary(binary) do
    case binary do
      <<"RIFF", _riff_len::little-32, "WAVE", chunks::binary>> -> walk(chunks, nil, nil)
      _ -> {:error, :not_a_wav}
    end
  end

  def parse(_binary), do: {:error, :not_a_wav}

  @doc "Read and parse a WAV file from disk."
  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, binary} -> parse(binary)
      {:error, reason} -> {:error, reason}
    end
  end

  # RIFF chunks are word-aligned: an odd-sized chunk carries a pad byte that is
  # not part of its body and not part of the next chunk's id.
  defp walk(<<>>, fmt, data), do: finish(fmt, data)

  defp walk(<<id::binary-4, size::little-32, rest::binary>>, fmt, data) do
    pad = rem(size, 2)

    case rest do
      <<body::binary-size(size), _pad::binary-size(pad), tail::binary>> ->
        case id do
          "fmt " -> walk(tail, parse_fmt(body), data)
          "data" -> walk(tail, fmt, body)
          _ -> walk(tail, fmt, data)
        end

      # A chunk claiming more bytes than the file holds. The common cause is a
      # truncated download; refuse rather than guessing at the tail.
      _ ->
        {:error, :malformed_wav}
    end
  end

  defp walk(_trailing, fmt, data), do: finish(fmt, data)

  defp finish(nil, _data), do: {:error, :malformed_wav}
  defp finish(_fmt, nil), do: {:error, :malformed_wav}
  defp finish({:error, reason}, _data), do: {:error, reason}

  defp finish({rate, channels, bits}, data) do
    # `frame` cannot be zero here: `parse_fmt/1` only returns a tuple when
    # `channels > 0` and `bits in [8, 16, 24, 32]`, so the product is at least 1.
    # A `frame == 0` guard used to sit here; Dialyzer proved it unreachable, and
    # a malformed header is already answered by parse_fmt's fallback clause.
    frame = div(bits, 8) * channels

    # A trailing partial frame cannot be played and breaks every index
    # calculation below; drop it rather than carrying a half-sample.
    {:ok,
     %__MODULE__{
       sample_rate: rate,
       channels: channels,
       bits: bits,
       data: binary_part(data, 0, byte_size(data) - rem(byte_size(data), frame))
     }}
  end

  # Format 1 is PCM. 0xFFFE is WAVE_FORMAT_EXTENSIBLE, which for our purposes is
  # PCM wearing a longer hat — the fields we read sit in the same places.
  defp parse_fmt(
         <<format::little-16, channels::little-16, rate::little-32, _byte_rate::little-32,
           _block_align::little-16, bits::little-16, _extra::binary>>
       )
       when format in [1, 0xFFFE] and channels > 0 and rate > 0 and bits in [8, 16, 24, 32] do
    {rate, channels, bits}
  end

  # Anything else is a compressed payload in a WAV wrapper (µ-law, ADPCM, …).
  # It is not malformed, it is simply not something this module decodes — and
  # `import_source/1` knows to hand those to afconvert.
  defp parse_fmt(_body), do: {:error, :unsupported_encoding}

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  @doc """
  Render a clip as a complete WAV binary.

  Emits the same minimal 44-byte header `SoundGen` writes, so
  `render(parse(x)) == x` holds byte-for-byte for anything the synthesizer
  produced — pinned by test, because a round trip that quietly rewrites the
  header would make every future "did this edit change the file?" check useless.
  """
  def render(%__MODULE__{} = clip) do
    block_align = div(clip.bits, 8) * clip.channels
    byte_rate = clip.sample_rate * block_align
    len = byte_size(clip.data)

    <<"RIFF", 36 + len::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
      clip.channels::little-16, clip.sample_rate::little-32, byte_rate::little-32,
      block_align::little-16, clip.bits::little-16, "data", len::little-32>> <> clip.data
  end

  @doc "Render a clip and write it to `path`."
  def write(%__MODULE__{} = clip, path) when is_binary(path) do
    File.write(path, render(clip))
  end

  # ---------------------------------------------------------------------------
  # Measurement
  # ---------------------------------------------------------------------------

  @doc "Frames in the clip (samples per channel)."
  def sample_count(%__MODULE__{} = clip), do: div(byte_size(clip.data), frame_bytes(clip))

  @doc "Clip length in milliseconds."
  def duration_ms(%__MODULE__{} = clip), do: sample_count(clip) * 1000 / clip.sample_rate

  @doc """
  Largest absolute sample as a fraction of full scale. `0.0` for silence; can
  exceed `1.0` by one step, because int16's negative rail (-32768) is one
  louder than its positive one (32767).
  """
  def peak(%__MODULE__{bits: 16} = clip) do
    clip.data
    |> samples()
    |> Enum.reduce(0, fn s, acc -> max(acc, abs(s)) end)
    |> Kernel./(32_767)
  end

  # ---------------------------------------------------------------------------
  # Edits
  # ---------------------------------------------------------------------------

  @doc """
  Cut `[from_ms, to_ms)` out of a clip — **half-open**: the `from` sample is
  included, the `to` sample is not.

  That convention is the answer to the classic splice bug. With an inclusive
  end, two adjacent cuts (`0–500`, `500–1000`) both contain the sample at 500,
  so concatenating them repeats it — a one-sample discontinuity, which is
  audible as a click precisely because it is a step change. Half-open makes
  adjacent cuts tile exactly.

  Out-of-range values clamp to the clip. A selection that ends at or before it
  starts is refused rather than silently producing an empty file.
  """
  def splice(%__MODULE__{} = clip, from_ms, to_ms)
      when is_number(from_ms) and is_number(to_ms) do
    total = sample_count(clip)
    from = clamp_int(ms_to_samples(from_ms, clip.sample_rate), 0, total)
    to = clamp_int(ms_to_samples(to_ms, clip.sample_rate), 0, total)

    if to <= from do
      {:error, :empty_selection}
    else
      frame = frame_bytes(clip)
      {:ok, %{clip | data: binary_part(clip.data, from * frame, (to - from) * frame)}}
    end
  end

  @doc """
  Linear fade in and/or out. `fade(clip, in_ms: 5, out_ms: 20)`.

  The ramps **land on true zero** at the very first and very last sample, which
  is the entire point: `SoundGen` shapes its own envelopes, but a clip cut out
  of the middle of a voicemail starts and ends mid-waveform, and a mid-waveform
  start is a step from silence to full amplitude — the loudest click a sound
  can begin with.

  Ramps longer than the clip are clamped; overlapping ramps multiply, which
  stays monotonic and cannot exceed unity.
  """
  def fade(%__MODULE__{bits: 16} = clip, opts) when is_list(opts) do
    total = sample_count(clip)
    in_n = clamp_int(ms_to_samples(Keyword.get(opts, :in_ms, 0), clip.sample_rate), 0, total)
    out_n = clamp_int(ms_to_samples(Keyword.get(opts, :out_ms, 0), clip.sample_rate), 0, total)

    if in_n <= 1 and out_n <= 1 do
      clip
    else
      map_samples(clip, fn s, i ->
        s * ramp_in(i, in_n) * ramp_out(total - 1 - i, out_n)
      end)
    end
  end

  # A one-sample ramp has no slope to speak of and would only silence a lone
  # sample, so it is treated as "no fade" rather than as a special case.
  defp ramp_in(i, n) when n > 1 and i < n, do: i / (n - 1)
  defp ramp_in(_i, _n), do: 1.0

  defp ramp_out(from_end, n) when n > 1 and from_end < n, do: from_end / (n - 1)
  defp ramp_out(_from_end, _n), do: 1.0

  @doc """
  Scale a clip so its loudest sample sits at `target` (default ~-1 dBFS).

  Silence is returned untouched — there is no gain that makes zero louder, and
  dividing by that peak is how a normalize function crashes on an empty
  selection.
  """
  def normalize(%__MODULE__{bits: 16} = clip, target \\ @default_target)
      when is_number(target) and target > 0 do
    case peak(clip) do
      p when p <= 0.0 -> clip
      p -> map_samples(clip, fn s, _i -> s * (target / p) end)
    end
  end

  @doc """
  Place clips at millisecond offsets and sum them into one clip — the render
  behind a multi-lane arrangement.

  Takes `[{clip, start_ms}, ...]`. Gaps become silence, overlaps **add**, and
  the result runs from 0 to the furthest clip's end. Unlike `concat/1` this is
  a mix, not a join: two clips at the same offset are heard together, which is
  the entire point of stacked lanes.

  Summing is where an arrangement clips. Four sounds at -6 dBFS landing on the
  same beat sum past full scale, so every sample goes through the same clamp as
  everything else here — and `normalize/2` afterwards is the honest fix, which
  is why the arranger offers it rather than silently attenuating.

  Refuses a render longer than #{div(@max_mix_ms, 1000)} seconds: the mix is
  built as integer lists, so length is memory, and a stray clip dragged to the
  far end of a ruler should report rather than swap the machine to death.
  """
  def mixdown([]), do: {:error, :empty_selection}

  def mixdown(placements) when is_list(placements) do
    clips = Enum.map(placements, fn {clip, _at} -> clip end)

    cond do
      not Enum.all?(clips, &match?(%__MODULE__{bits: 16}, &1)) ->
        {:error, :format_mismatch}

      not Enum.all?(clips, &same_format?(&1, hd(clips))) ->
        {:error, :format_mismatch}

      true ->
        do_mixdown(placements, hd(clips))
    end
  end

  defp do_mixdown(placements, %__MODULE__{sample_rate: rate} = first) do
    placed =
      Enum.map(placements, fn {clip, at} ->
        {samples(clip.data), max(0, ms_to_samples(at, rate))}
      end)

    total = placed |> Enum.map(fn {s, off} -> off + length(s) end) |> Enum.max()

    if total > ms_to_samples(@max_mix_ms, rate) do
      {:error, :too_long}
    else
      lanes =
        Enum.map(placed, fn {s, off} ->
          List.duplicate(0, off) ++ s ++ List.duplicate(0, total - off - length(s))
        end)

      data =
        lanes
        |> Enum.zip_with(&Enum.sum/1)
        |> Enum.reduce(<<>>, fn sum, acc -> <<acc::binary, clamp16(sum)::little-signed-16>> end)

      {:ok, %{first | data: data}}
    end
  end

  @doc """
  Join clips end to end. Every clip must share one format — joining a 44.1 kHz
  clip onto a 22.05 kHz one would play the first at half speed, so the mismatch
  is an error rather than a resample nobody asked for.
  """
  def concat([]), do: {:error, :empty_selection}
  def concat([%__MODULE__{} = clip]), do: {:ok, clip}

  def concat([%__MODULE__{} = first | rest] = clips) do
    if Enum.all?(rest, &same_format?(&1, first)) do
      {:ok, %{first | data: clips |> Enum.map(& &1.data) |> IO.iodata_to_binary()}}
    else
      {:error, :format_mismatch}
    end
  end

  # ---------------------------------------------------------------------------
  # Import — the one door to the outside world
  # ---------------------------------------------------------------------------

  @doc """
  Load any audio file as an internal-format clip.

  Named `import_source/1` rather than `import/1` because `import` is a
  `Kernel.SpecialForms` macro and cannot be defined as a function.

  A file that already parses as PCM16 mono 22.05 kHz is taken as-is — no
  subprocess for our own chimes. Everything else goes through `afconvert`,
  which resamples and downmixes on the way in, so a 44.1 kHz stereo mp3 needs
  no resampling code here.

  Failures are reported, never raised: `:not_found`, `:no_decoder` (the system
  binary is missing or unreachable — the case a sandboxed packaged build may
  produce, see Phase 5), or `:unsupported_source`.
  """
  def import_source(path) when is_binary(path) do
    if File.regular?(path) do
      case read(path) do
        {:ok, %__MODULE__{} = clip} -> if internal?(clip), do: {:ok, clip}, else: decode(path)
        {:error, _reason} -> decode(path)
      end
    else
      {:error, :not_found}
    end
  end

  def import_source(_path), do: {:error, :not_found}

  @doc "True when the system decoder is available. Phase 5's question, asked cheaply."
  def decoder_available?, do: File.regular?(@decoder)

  @prober "/usr/bin/afinfo"

  @doc """
  Header-read facts about an audio file — duration, sample rate, channels —
  without decoding a byte of audio.

  `/usr/bin/afinfo` is `afconvert`'s sibling: the same licensing-free system
  toolbox, and O(header) regardless of file size. That is the point: inline
  decodes are capped at a few MB because they materialize the whole file as
  PCM, but a twenty-minute recording still deserves a length. Returns
  `{:ok, %{duration_ms: float, sample_rate: int, channels: int}}`, or
  `{:error, :not_found | :no_prober | :unsupported_source}`.
  """
  def probe(path) when is_binary(path) do
    cond do
      not File.regular?(path) -> {:error, :not_found}
      not File.regular?(@prober) -> {:error, :no_prober}
      true -> run_probe(path)
    end
  end

  def probe(_path), do: {:error, :not_found}

  defp run_probe(path) do
    # A list of args, so this never reaches a shell (same rule as decode/1).
    case System.cmd(@prober, [path], stderr_to_stdout: true) do
      {output, 0} -> parse_probe(output)
      {_output, _status} -> {:error, :unsupported_source}
    end
  rescue
    _error -> {:error, :no_prober}
  end

  # afinfo prints, for every format it understands:
  #
  #     Data format:     2 ch,  44100 Hz, ...
  #     estimated duration: 0.809977 sec
  #
  # ("estimated" is afinfo's word even when the header is exact.)
  defp parse_probe(output) do
    with [_, secs] <- Regex.run(~r/estimated duration:\s*([\d.]+)\s*sec/, output),
         [_, ch, hz] <- Regex.run(~r/Data format:\s*(\d+)\s+ch,\s*([\d.]+)\s*Hz/, output),
         {duration, _} <- Float.parse(secs),
         {rate, _} <- Float.parse(hz) do
      {:ok,
       %{
         duration_ms: duration * 1000.0,
         sample_rate: trunc(rate),
         channels: String.to_integer(ch)
       }}
    else
      _ -> {:error, :unsupported_source}
    end
  end

  defp decode(path) do
    if decoder_available?() do
      tmp = Path.join(System.tmp_dir!(), "bcstudio-#{:erlang.unique_integer([:positive])}.wav")

      try do
        # A list of args, so this never reaches a shell — a filename containing
        # a quote or a semicolon is data, not syntax.
        case System.cmd(
               @decoder,
               ["-f", "WAVE", "-d", "LEI16@#{@rate}", "-c", "#{@channels}", path, tmp],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> read(tmp)
          {_output, _status} -> {:error, :unsupported_source}
        end
      rescue
        # System.cmd raises if the binary vanishes between the check and the
        # call, or cannot be executed at all.
        _error -> {:error, :no_decoder}
      after
        File.rm(tmp)
      end
    else
      {:error, :no_decoder}
    end
  end

  # ---------------------------------------------------------------------------
  # The workspace folder — where imported raw material lives
  # ---------------------------------------------------------------------------

  @doc """
  Absolute path to `<workspace>/studio/`, the studio's own folder.

  **Deliberately not `sounds/`.** That folder is the *effects library*, where a
  file overrides a bundled chime by basename (`Sound.resolve_path/1`) — so
  importing a three-minute voicemail into it would silently enlist that
  recording as a candidate chime. `studio/` holds raw material you are working
  on; `sounds/` holds finished effects. Saving an edit as a chime is the
  deliberate step that moves audio from the first to the second.
  """
  def dir, do: Artifact.workspace_path(@subdir)

  @doc "Extensions the studio accepts on import — everything `afconvert` decodes."
  def accepted_extensions, do: @import_exts

  @doc "The audio content-type for a basename, for the serving route."
  def content_type(name) when is_binary(name) do
    Map.get(
      @content_types,
      name |> Path.extname() |> String.downcase(),
      "application/octet-stream"
    )
  end

  @doc """
  Create `<workspace>/studio/` and a README explaining what it is for, so the
  folder is discoverable in the Workspace tab and in Finder. Best-effort — a
  workspace that cannot be written is not a reason to refuse to boot.
  """
  def ensure do
    File.mkdir_p(dir())
    readme = Path.join(dir(), "README.md")
    unless File.exists?(readme), do: File.write(readme, readme_body())
    :ok
  rescue
    error ->
      Logger.warning("SoundStudio.ensure failed: #{Exception.message(error)}")
      :ok
  end

  @doc "Sorted basenames of every audio file in the studio folder."
  def list do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn name ->
          String.downcase(Path.extname(name)) in @import_exts and
            File.regular?(Path.join(dir(), name))
        end)
        |> Enum.sort_by(&String.downcase/1)

      _ ->
        []
    end
  end

  @doc """
  Absolute path for a studio file by basename, or `nil`. Membership in `list/0`
  is the allowlist — a name that is not a real directory entry never resolves,
  so raw input is never joined into a path.
  """
  def path_for(name) when is_binary(name) do
    if name in list(), do: Path.join(dir(), name)
  end

  def path_for(_name), do: nil

  @doc """
  Import an uploaded file into the studio folder under a safe, collision-free
  name.

  **The gate is a decode, not an extension.** `import_source/1` has to succeed
  before anything is written, which means the studio only ever holds files it
  can actually edit — a `.wav` full of prose is refused here rather than
  becoming a sidebar entry that fails the moment you select it.
  """
  def store(source_path, client_name) when is_binary(source_path) and is_binary(client_name) do
    ext = client_name |> Path.extname() |> String.downcase()

    cond do
      ext not in @import_exts -> {:error, :unsupported_format}
      not File.regular?(source_path) -> {:error, :enoent}
      match?({:error, _}, import_source(source_path)) -> {:error, :not_audio}
      true -> copy_in(source_path, client_name)
    end
  end

  def store(_source, _name), do: {:error, :unsupported_format}

  defp copy_in(source_path, client_name) do
    File.mkdir_p(dir())
    name = available_name(Music.safe_name(client_name))

    case File.cp(source_path, Path.join(dir(), name)) do
      :ok -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Write an edited clip into the studio folder under a safe, collision-free name.

  The extension is forced to `.wav` because that is what `render/1` produces —
  a trim of `voicemail.mp3` saved as `voicemail-trim.mp3` would be a WAV lying
  about its container, and every decoder that trusted the name would choke.

  Never overwrites: the source of an edit and its result coexist, so a trim you
  regret costs nothing.
  """
  def save(%__MODULE__{} = clip, suggested_name) when is_binary(suggested_name) do
    File.mkdir_p(dir())
    name = available_name(Music.safe_name(Path.rootname(suggested_name) <> ".wav"))

    case write(clip, Path.join(dir(), name)) do
      :ok -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Rename an imported file, keeping its extension.

  Callers must retarget any mix clip that referenced it — a clip stores
  `"import:<name>"`, so the rename would otherwise leave it pointing at nothing.
  `StudioMix.retarget/2` is that step; `SoundStudioComponent` does both together.
  """
  def rename(name, stem) when is_binary(name) and is_binary(stem) do
    with path when is_binary(path) <- path_for(name),
         {:ok, new_name} <- BusterClaw.Notifications.Sound.renamed_to(name, stem),
         false <- new_name in list(),
         :ok <- File.rename(path, Path.join(dir(), new_name)) do
      {:ok, new_name}
    else
      nil -> {:error, :not_found}
      true -> {:error, :name_taken}
      {:error, _reason} = error -> error
    end
  end

  def rename(_name, _stem), do: {:error, :not_found}

  @doc "Remove a file from the studio folder."
  def delete(name) when is_binary(name) do
    case path_for(name) do
      nil -> {:error, :not_found}
      path -> File.rm(path)
    end
  end

  def delete(_name), do: {:error, :not_found}

  # Two imports of the same name coexist as `clip.wav` / `clip-2.wav` rather
  # than one silently replacing the other.
  defp available_name(name) do
    if File.exists?(Path.join(dir(), name)), do: next_free(name, 2), else: name
  end

  defp next_free(name, n) do
    stem = Path.rootname(name)
    candidate = "#{stem}-#{n}#{Path.extname(name)}"
    if File.exists?(Path.join(dir(), candidate)), do: next_free(name, n + 1), else: candidate
  end

  defp readme_body do
    """
    # Studio

    Audio you are working on, from the Studio tab on the home page.

    Import a file here and you can trim it, shape it, and save the result as a
    notification sound effect. Anything you drop into this folder from Finder
    shows up in the Studio too — this is your disk, not a database.

    - Accepted: `.mp3`, `.m4a`, `.aac`, `.wav`, `.ogg`, `.flac`.
    - Finished sound effects live one folder over, in `sounds/`, where they
      replace the app's built-in chimes by filename.
    - Deleting anything here is safe; it is raw material, not configuration.
    """
  end

  # ---------------------------------------------------------------------------
  # Sample plumbing
  # ---------------------------------------------------------------------------

  defp frame_bytes(%__MODULE__{} = clip), do: div(clip.bits, 8) * clip.channels

  defp samples(data), do: for(<<s::little-signed-16 <- data>>, do: s)

  defp map_samples(%__MODULE__{} = clip, fun) do
    data =
      clip.data
      |> samples()
      |> Enum.with_index()
      |> Enum.reduce(<<>>, fn {s, i}, acc ->
        <<acc::binary, clamp16(fun.(s, i))::little-signed-16>>
      end)

    %{clip | data: data}
  end

  # Every write goes through here. Rounding a scaled sample can land one step
  # outside int16, and a wrapped sample is not quiet distortion — it is a
  # full-scale sign flip, the loudest possible artifact.
  defp clamp16(value) do
    value |> round() |> clamp_int(-32_768, 32_767)
  end

  defp clamp_int(value, lo, hi), do: value |> max(lo) |> min(hi)

  defp ms_to_samples(ms, rate), do: round(ms * rate / 1000)

  defp same_format?(%__MODULE__{} = a, %__MODULE__{} = b) do
    a.sample_rate == b.sample_rate and a.channels == b.channels and a.bits == b.bits
  end
end
