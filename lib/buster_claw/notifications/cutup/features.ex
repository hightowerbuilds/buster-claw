defmodule BusterClaw.Notifications.Cutup.Features do
  @moduledoc """
  The feature layer of the cut-up recogniser (STUDIO_ROADMAP Part III, between
  V.1 and V.4): run a source recording all the way from PCM to MFCCs **once**,
  and keep the answer.

  `Signal` turns samples into frames and spectra. `Mfcc` turns one spectrum into
  thirteen coefficients. `Dtw` compares two sequences of them. Nothing in that
  stack knows about a file, a workspace, or a second query — so until this module
  existed, every search would have re-derived the whole corpus from scratch. This
  is the layer that makes the pipeline *reachable*: `for_source/2` is the one call
  a searcher makes, and it costs a minute or two the first time and a sixth of a
  second after that.

  ## Why a cache, in numbers

  The measured corpus is 295 s at 22.05 kHz — ~29,500 frames, each a 1024-point
  FFT plus a 26-band filterbank and a 13×26 DCT. `Signal`'s moduledoc measures
  its own half at ~40 s single-core on an idle machine and ~130 s under
  contention. **Measured here, end to end on a 300 s source with four other test
  suites running beside it:**

  | | 300 s source, 29,998 frames |
  |---|---|
  | cold `for_source/2` (compute + encode + write) | **108.8 s** |
  | warm `for_source/2` (stat + digest + read + decode) | **~155 ms** |

  That is a **700x** difference, and it is the whole justification for this
  module. Searching one template against every source means reading every
  source's features; doing that by recomputing would make the feature unusable at
  the second question. An index is built once and saved. So are features. **The
  cache is not an optimisation here; it is the difference between a feature and a
  demo.**

  A warm hit is *not* free, and the breakdown is worth knowing before anyone
  optimises the wrong end: of those 155 ms, ~30 ms is the SHA-256 of a 12.6 MiB
  source and most of the rest is turning 390,000 IEEE-754 doubles into a list of
  lists. Over a 60-file corpus that is ~9 s per whole-corpus query. If that ever
  becomes the bottleneck, the fix is a representation the decode does not have to
  materialise — not a faster hash, and not a smaller file.

  ## Where the cache lives

      <workspace>/sounds/studio/           # the sources, SoundStudio.dir/0
      <workspace>/sounds/studio/index/     # word indexes, Cutup.Index.dir/0
      <workspace>/sounds/studio/features/  # one <source><ext>.features.bin each

  Alongside the index, for the same reason and with the same naming rule: the
  filename carries the **full source basename including its audio extension**
  (`voicemail-03.wav.features.bin`), so `voicemail-03.wav` and `voicemail-03.mp3`
  cache separately instead of silently sharing one file. `SoundStudio.list/0`
  only reports regular files with audio extensions, so this directory never
  appears as an importable clip.

  Unlike an index, **a feature file is not hand-editable and is not meant to be.**
  It is a derived artefact: delete it and it comes back identical. That is why it
  can be cached at all, and why `Cutup.Index` deliberately refuses to cache
  itself — an index is a document an operator corrects by hand.

  ## A source is a basename, and that is a security boundary

  Every entry point runs its `source` through `Cutup.SourceName.safe/1` — the
  same *function* `Cutup.Index` calls, not the same rules re-stated: no `/`, no
  `\\`, no `..`, no null byte, nothing `Path.basename/1` would shorten, and the
  name must survive `BusterClaw.AudioName.safe_name/1` unchanged (compared
  case-insensitively, so a real `VOICE.WAV` is not refused for that sanitizer's
  extension-case rewrite). A cache entry therefore cannot name a file outside the
  studio's sources directory. Resolution to a real path then goes through
  `SoundStudio.path_for/1`, whose allowlist is membership in `SoundStudio.list/0`
  — so raw input is never joined into a path.

  ## CMN runs over the WHOLE recording, and that is the point of caching here

  `t:BusterClaw.Notifications.Cutup.Types.feature_seq/0` spells out the trap: the
  cepstral mean must be taken over a **whole recording**, and the template sliced
  out of the *already normalised* sequence. Over a two-word snippet the mean is
  substantially the speech itself, so normalising it subtracts the signal along
  with the channel — with no error, no crash, and no symptom except results that
  are quietly poor.

  **What this module stores is the whole recording, normalised.** A caller wanting
  a template slices `Enum.slice(seq, frame0..frame1)` out of what `for_source/2`
  returns. Getting a template by calling `compute/2` on a *cut-out clip* is the
  backwards version, and it will not error.

  Corollary, and it is the other half of the same trap: the cached sequence is
  **already normalised**, so `Cutup.Dtw`'s opt-in `:cmn` must stay off. Applying
  it twice subtracts an already-zero mean over a different window and silently
  rescales the distance, so a tuned threshold stops transferring.

  ## The FFT size defaults disagree upstream, and this module reconciles them

  `Signal.default_fft_size/0` is **1024**; `Mfcc.new/1`'s default `:fft_size` is
  **512**. Both are right for their own module — 25 ms at 22.05 kHz is 551
  samples, so 512 would truncate a frame, while `Mfcc` predates that measurement.
  Wired naively, `Mfcc.new([])` builds a 257-bin bank, `Signal.frames/2` produces
  513-bin spectra, and `features/2` raises on the bin count.

  So **`compute/2` passes one `:fft_size` to both stages** and defaults it to
  `Signal.default_fft_size/0`. This is the kind of seam that only exists once
  something actually connects two modules, which is why it is written here.

  ## Cache invalidation, which is the part that bites

  A stored feature file is valid for **exactly one audio file and exactly one set
  of analysis parameters**. A stale hit does not raise: it produces confident,
  well-formed, wrong distances. So the header carries everything that could
  change the numbers, and **any mismatch recomputes rather than trusts**:

  - **Source identity** — byte size, POSIX mtime, and a **SHA-256 of the file's
    bytes**. Size and mtime are the cheap screen; the digest is the authority.
    Both are kept because size+mtime alone has a real hole: mtime has one-second
    granularity, so a source re-saved at the same length within the same second
    is byte-different and stat-identical. Measured, hashing costs **30 ms on a
    12.6 MiB recording** against the 109 s it guards — a trade not worth thinking
    about twice, though it is most of what stops a hit being instant.
  - **Analysis parameters** — `fft_size`, `pre_emphasis`, `n_filters`,
    `n_coeffs`, `cmn`, plus `frame_ms` and `hop_ms` read from `Signal` so that
    changing the pinned frame geometry invalidates every file on disk rather
    than silently mixing clocks.
  - **The format magic**, `BCFEAT1`. A future encoding bumps the digit and
    every older file is refused, which is cheaper and safer than a migration.

  `sample_rate` is **recorded but not compared**. It is a property of the audio,
  and the audio is already pinned bit-for-bit by the digest; comparing it would
  require decoding the source before deciding whether to decode the source. It is
  in the header because a reader of the file deserves to see what it was built
  for.

  Nothing about the payload's own claims is trusted: the frame count and
  dimension in the header are checked against the payload's actual byte length,
  and a float that will not decode (a NaN or infinity bit pattern, which Erlang's
  binary matching refuses) fails the read. A failed read is never an error to the
  caller — it recomputes.

  ## On-disk format, and what it costs

      "BCFEAT1\\n" <> <one-line JSON header> <> "\\n" <> <IEEE-754 float64, big-endian>

  A readable header so `head -c 400` tells you exactly what a file is and what it
  was built for, and a raw payload because these are large float arrays and
  nothing else is honest about them. **Measured on 5 minutes of audio — 29,998
  frames × 13 coefficients:**

  | encoding | bytes | |
  |---|---|---|
  | **float64 payload + header (this)** | **3,120,077** | **2.976 MiB** |
  | the same payload through `:zlib.compress/1` | 2,983,960 | 95.6% of raw |
  | `:erlang.term_to_binary/1` | 3,689,761 | +18% |
  | `:erlang.term_to_binary/2`, `compressed: 9` | 3,142,780 | +1%, and CPU per read |
  | JSON at round-trip precision | ~7,726,885 | 2.5x, and slower to parse |

  The header is 285 bytes of it; the payload is exactly `frames × dims × 8`.

  Float64 rather than float32 because the file must round-trip to the *same*
  floats: a threshold study measured to two decimals against distances in the
  3–13 range does not want a silent 1e-7 wobble under it. **Uncompressed because
  the measurement says compression is not worth it** — mantissa bits are close to
  incompressible, so zlib returns 4.4% and charges an inflate on every read — and
  because a raw payload lets the reader validate the shape with byte arithmetic
  before it decodes anything.

  ## Parallelism, and the one finding that shapes it

  Indexing several sources is embarrassingly parallel and `warm/2` is one
  `Task.async_stream`. But `Signal`'s moduledoc records the surprise that matters
  here: **throughput halves on long clips**, because framing is eager and a
  10-second clip leaves ~1M live floats on the process heap for every subsequent
  GC to walk. The answer is **one file per process** — which `warm/2` gives you
  for free, and which is also why it returns *frame counts* rather than the
  sequences themselves. Handing 30,000×13 floats per source back to the caller
  would copy every corpus into one heap and reproduce exactly the GC pressure the
  per-process split exists to avoid. Ask for the data with `for_source/2`, which
  is a cache hit by then.

  There is no timeout: a single source legitimately takes a minute under load,
  and killing it halfway is strictly worse than waiting.

  ## Totality

  Nothing here raises. A missing source, a corrupt cache, a source the studio
  cannot decode, a traversal attempt: each has a named result. `compute/2` is the
  one exception, and deliberately — it is the pure function, and it inherits
  `Signal`'s and `Mfcc`'s refusal to return wrong numbers for a bad geometry.
  `for_source/2` converts those refusals into `{:error, :unsupported_format}`.

  ## Limits worth stating plainly

  - **The cache is per-source, not per-corpus.** There is no manifest, so `list/0`
    is a directory read and a corpus-wide check is N stats and N digests. At the
    hundreds of files a workspace realistically holds that is milliseconds.
  - **A cache hit still reads and hashes the whole source file.** That is the
    price of the digest: a hit on a 5-minute source is ~155 ms, not ~1 ms.
  - **No band limiting.** The mel bank always spans DC to Nyquist. Telephony
    would want 300–3400 Hz, and that is a real improvement to make — as a new
    option *and* a bump to `BCFEAT2`, so no existing file survives the change.
  - **Nothing here is a matcher.** These are numbers about sound; deciding two
    spans are the same word is `Dtw`'s.
  """

  require Logger

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Notifications.Cutup.Mfcc
  alias BusterClaw.Notifications.Cutup.Signal
  alias BusterClaw.Notifications.Cutup.SourceName
  alias BusterClaw.Notifications.Cutup.Types
  alias BusterClaw.Notifications.SoundStudio

  @subdir Path.join(["sounds", "studio", "features"])
  @ext ".features.bin"

  # Bump the digit for any change to the encoding, the header's meaning, or the
  # set of parameters that decide validity. Every older file is then refused and
  # recomputed, which is the whole migration strategy.
  @magic "BCFEAT1"

  @default_pre_emphasis 0.97
  @default_filters 26
  @default_coeffs 13

  @typedoc "A source basename inside the studio's sources directory."
  @type source :: String.t()

  @typedoc """
  Analysis parameters. Every one of these is part of the cache key: change any
  and the stored file for that source is refused rather than trusted.

  - `:fft_size` — the power-of-two length each frame is padded to. Defaults to
    `Signal.default_fft_size/0` (1024) and is passed to **both** `Signal` and
    `Mfcc`; see the moduledoc on why their own defaults disagree.
  - `:pre_emphasis` — the one-tap high-pass coefficient (0.97).
  - `:n_filters` — mel filters (26).
  - `:n_coeffs` — coefficients kept from the DCT (13).
  - `:cmn` — cepstral mean normalisation over the whole sequence. **On by
    default, and it should stay on**; see the moduledoc.
  """
  @type opts :: [
          fft_size: pos_integer(),
          pre_emphasis: float(),
          n_filters: pos_integer(),
          n_coeffs: pos_integer(),
          cmn: boolean()
        ]

  @typedoc "Why a call was refused. Every one of these is returned, never raised."
  @type error ::
          :invalid_source
          | :unsafe_source
          | :not_found
          | :unsupported_format
          | :no_decoder
          | :file.posix()

  # ---------------------------------------------------------------------------
  # Location
  # ---------------------------------------------------------------------------

  @doc "Absolute path to `<workspace>/sounds/studio/features/`."
  @spec dir() :: String.t()
  def dir, do: Artifact.workspace_path(@subdir)

  # ---------------------------------------------------------------------------
  # The pure half
  # ---------------------------------------------------------------------------

  @doc """
  A whole clip's feature sequence: frames → spectra → MFCCs → **CMN over the
  whole sequence**.

  Pure, and the only function here that touches no disk. Frame `i` of the result
  starts at `Signal.frame_index_to_ms(i)`, so a caller holding a word's
  millisecond bounds reaches its template by slicing this list — *after* it has
  been normalised, never before. See the moduledoc, and
  `t:BusterClaw.Notifications.Cutup.Types.feature_seq/0`, on why that order is not
  interchangeable.

  A clip shorter than one 25 ms frame yields `[]`, inheriting `Signal.frames/2`'s
  refusal to pad a frame that is mostly silence and call it comparable.

  Raises `ArgumentError` on a geometry that cannot produce sensible features —
  a clip that is not mono PCM16, an `fft_size` too small to hold a frame, more
  coefficients than filters. It is the pure function, so it refuses rather than
  returning numbers that merely look right; `for_source/2` turns those into
  `{:error, :unsupported_format}`.
  """
  @spec compute(SoundStudio.t(), opts()) :: Types.feature_seq()
  def compute(clip, opts \\ [])

  def compute(%SoundStudio{} = clip, opts) when is_list(opts) do
    params = params(opts)

    bank =
      Mfcc.new(
        fft_size: params.fft_size,
        sample_rate: clip.sample_rate,
        n_filters: params.n_filters,
        n_coeffs: params.n_coeffs
      )

    seq =
      clip
      |> Signal.frames(fft_size: params.fft_size, pre_emphasis: params.pre_emphasis)
      |> Enum.map(fn frame -> frame |> Signal.spectrum() |> Mfcc.features(bank) end)

    # The whole recording, then the mean. Not the other way round.
    if params.cmn, do: Mfcc.cmn(seq), else: seq
  end

  # ---------------------------------------------------------------------------
  # The cache
  # ---------------------------------------------------------------------------

  @doc """
  The feature sequence for a source basename, from the cache when it is valid and
  freshly computed when it is not.

  **This is the call a searcher makes.** It is a whole-corpus-worth of arithmetic
  the first time and a file read after that, and the caller cannot tell which
  happened except by the clock — which is the intended shape, because a stale
  cache is never returned in place of a correct answer.

  A miss is not only "no file". The stored entry is refused, and the features
  recomputed, when the source's bytes have changed (size, mtime or SHA-256), when
  any analysis parameter differs from `opts`, when the format magic is older, or
  when the file is truncated, corrupt, or disagrees with its own header. See the
  moduledoc for the full list and why each is in it.

  Failing to *write* the cache is not failure: the features are returned and a
  warning is logged, because a read-only workspace should be slow rather than
  broken.

  Errors: `:invalid_source` / `:unsafe_source` for a name that is not a plain
  basename inside the studio; `:not_found` when the studio holds no such file;
  `:unsupported_format` when the source cannot be decoded to mono PCM16.
  """
  @spec for_source(source(), opts()) :: {:ok, Types.feature_seq()} | {:error, error()}
  def for_source(source, opts \\ [])

  def for_source(source, opts) when is_binary(source) and is_list(opts) do
    with {:ok, name} <- safe_source(source),
         {:ok, path} <- source_path(name),
         {:ok, identity} <- identify(path) do
      params = params(opts)

      case read_cache(name, identity, params) do
        {:ok, seq} -> {:ok, seq}
        {:error, _reason} -> miss(name, path, identity, params)
      end
    end
  end

  def for_source(_source, _opts), do: {:error, :invalid_source}

  @doc """
  Compute and store features for several sources at once, one file per process.

  Returns a map from every source given to `{:ok, frame_count}` or
  `{:error, reason}` — **every** source, so a caller can see which failed rather
  than inferring it from a shorter list. Sources that already have a valid cache
  are counted without being recomputed, so calling this twice is cheap.

  It returns counts and not sequences on purpose: see the moduledoc on why
  hauling every corpus back into one heap defeats the per-process split. Ask for
  the data with `for_source/2` afterwards, which is a hit by then.

  `:max_concurrency` defaults to `System.schedulers_online/0`. There is no
  timeout — a single source legitimately runs for a minute under load.
  """
  @spec warm([source()], opts()) :: %{
          source() => {:ok, non_neg_integer()} | {:error, error()}
        }
  def warm(sources, opts \\ [])

  def warm(sources, opts) when is_list(sources) and is_list(opts) do
    {concurrency, analysis} = Keyword.pop(opts, :max_concurrency, System.schedulers_online())

    sources = Enum.uniq(sources)

    # `ordered: true` is load-bearing, not tidiness. This function's contract is
    # that EVERY source comes back with a key, so a caller can see which failed
    # rather than inferring it from a shorter map. An `{:exit, reason}` tuple
    # carries no source name — so under `ordered: false` a crashed source is
    # unrecoverable and vanishes silently, which is precisely the contract this
    # promises not to break. Ordered, the position identifies it. The cost is
    # nil: results are collected into a map, so arrival order never mattered.
    sources
    |> Task.async_stream(
      fn source -> {source, counted(source, analysis)} end,
      max_concurrency: max(concurrency, 1),
      timeout: :infinity,
      ordered: true
    )
    |> Enum.zip(sources)
    |> Enum.reduce(%{}, fn
      {{:ok, {source, result}}, _source}, acc -> Map.put(acc, source, result)
      {{:exit, reason}, source}, acc -> Map.put(acc, source, {:error, {:crashed, reason}})
    end)
  end

  def warm(_sources, _opts), do: %{}

  defp counted(source, opts) do
    case for_source(source, opts) do
      {:ok, seq} -> {:ok, length(seq)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Whether a cache **file** exists for a source.

  Deliberately not "whether the cache is usable": validity depends on the
  parameters you intend to ask with and on the source's current bytes, and the
  only honest oracle for that is `for_source/2`, which either returns the stored
  answer or quietly replaces it. This reports what is on disk.
  """
  @spec cached?(term()) :: boolean()
  def cached?(source) when is_binary(source) do
    case safe_source(source) do
      {:ok, name} -> File.regular?(path_for(name))
      {:error, _reason} -> false
    end
  end

  def cached?(_source), do: false

  @doc """
  Delete a source's cached features. The audio and its index are untouched.

  `:not_found` when there was nothing to delete. Deleting is always safe — the
  entry is derived, and the next `for_source/2` rebuilds it identically.
  """
  @spec delete(source()) :: :ok | {:error, error()}
  def delete(source) when is_binary(source) do
    case safe_source(source) do
      {:ok, name} -> remove(path_for(name))
      {:error, _reason} = error -> error
    end
  end

  def delete(_source), do: {:error, :invalid_source}

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Source basenames that have a cache file, sorted. Never raises; `[]` if the directory is absent."
  @spec list() :: [source()]
  def list, do: SourceName.list_in(dir(), @ext)

  # ---------------------------------------------------------------------------
  # Miss: decode, compute, store
  # ---------------------------------------------------------------------------

  defp miss(name, path, identity, params) do
    case SoundStudio.import_source(path) do
      {:ok, clip} -> computed(name, clip, identity, params)
      {:error, :not_found} -> {:error, :not_found}
      {:error, :no_decoder} -> {:error, :no_decoder}
      {:error, _reason} -> {:error, :unsupported_format}
    end
  end

  defp computed(name, clip, identity, params) do
    seq = compute(clip, Map.to_list(params))
    store(name, clip, identity, params, seq)
    {:ok, seq}
  rescue
    # Signal and Mfcc refuse a geometry they cannot honour rather than returning
    # plausible-looking wrong numbers. That refusal is right, and it is not this
    # function's contract, so it becomes a named error here.
    error in ArgumentError ->
      Logger.warning("Cutup.Features cannot analyse #{name}: #{Exception.message(error)}")
      {:error, :unsupported_format}
  end

  defp store(name, clip, identity, params, seq) do
    result =
      with {:ok, body} <- encode(clip, identity, params, seq),
           :ok <- File.mkdir_p(dir()) do
        write_atomic(path_for(name), body)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        # A workspace that cannot be written should be slow, not broken.
        Logger.warning("Cutup.Features could not cache #{name}: #{inspect(reason)}")
        :ok
    end
  end

  # Rename is atomic within a filesystem, so a reader never sees a half-written
  # payload and two processes warming the same source cannot interleave.
  defp write_atomic(path, body) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, body),
         {:error, reason} <- File.rename(tmp, path) do
      _ = File.rm(tmp)
      {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Source identity — the half of the cache key that is not a parameter
  # ---------------------------------------------------------------------------

  defp source_path(name) do
    case SoundStudio.path_for(name) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  # Size and mtime are the cheap screen; the digest is the authority. See the
  # moduledoc on the same-size, same-second hole that makes both necessary.
  defp identify(path) do
    with {:ok, %File.Stat{size: size, mtime: mtime}} <- File.stat(path, time: :posix),
         {:ok, bytes} <- File.read(path) do
      {:ok,
       %{
         "bytes" => size,
         "mtime" => mtime,
         "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
       }}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Parameters
  # ---------------------------------------------------------------------------

  # Normalised so a stored header and a fresh request compare term-for-term: the
  # floats are floats, the integers are integers, and the pinned frame geometry
  # is read from Signal rather than restated, so changing the clock invalidates
  # every file on disk instead of silently mixing two of them.
  defp params(opts) do
    %{
      fft_size: integer(Keyword.get(opts, :fft_size), Signal.default_fft_size()),
      pre_emphasis: float(Keyword.get(opts, :pre_emphasis), @default_pre_emphasis),
      n_filters: integer(Keyword.get(opts, :n_filters), @default_filters),
      n_coeffs: integer(Keyword.get(opts, :n_coeffs), @default_coeffs),
      cmn: Keyword.get(opts, :cmn, true) != false,
      frame_ms: Signal.frame_ms(),
      hop_ms: Signal.hop_ms()
    }
  end

  defp integer(value, _default) when is_integer(value), do: value
  defp integer(_value, default), do: default

  defp float(value, _default) when is_number(value), do: value * 1.0
  defp float(_value, default), do: default

  defp param_map(params) do
    Map.new(params, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  # Compared key by key with `==` rather than by comparing the maps, because map
  # equality is exact on values and a JSON round trip is entitled to hand back
  # `25.0` where a fresh request holds `25`. A missing key is a mismatch; so is a
  # key whose stored value changed *kind*, which is why `is_number/1` is compared
  # on both sides before the values are.
  #
  # `stored` is always a map: it reaches here through `Map.take/2` on a decoded
  # JSON object, so there is no non-map clause to write.
  defp params_match?(stored, wanted) do
    want = param_map(wanted)

    map_size(stored) == map_size(want) and
      Enum.all?(want, fn {key, value} ->
        case Map.fetch(stored, key) do
          {:ok, found} -> is_number(found) == is_number(value) and found == value
          :error -> false
        end
      end)
  end

  # ---------------------------------------------------------------------------
  # Encoding
  # ---------------------------------------------------------------------------

  defp encode(clip, identity, params, seq) do
    case shape(seq) do
      {:ok, frames, dims} ->
        header =
          identity
          |> Map.merge(param_map(params))
          |> Map.merge(%{
            "version" => 1,
            "sample_rate" => clip.sample_rate,
            "frames" => frames,
            "dims" => dims
          })

        case Jason.encode(header) do
          {:ok, json} -> {:ok, @magic <> "\n" <> json <> "\n" <> payload(seq)}
          {:error, _reason} -> {:error, :invalid_features}
        end

      :error ->
        {:error, :invalid_features}
    end
  end

  # A ragged sequence means two different extractors produced it, which is not
  # something to write to disk and discover later. Only `compute/2`'s own output
  # reaches here, so the shape is a list of lists by construction and the
  # question is whether it is *uniform*.
  defp shape([]), do: {:ok, 0, 0}

  defp shape([first | _] = seq) do
    dims = length(first)

    if Enum.all?(seq, fn vec ->
         is_list(vec) and length(vec) == dims and Enum.all?(vec, &is_number/1)
       end) do
      {:ok, length(seq), dims}
    else
      :error
    end
  end

  defp payload(seq), do: for(vec <- seq, value <- vec, into: <<>>, do: <<value::float-64>>)

  # ---------------------------------------------------------------------------
  # Decoding — nothing the file claims about itself is trusted
  # ---------------------------------------------------------------------------

  defp read_cache(name, identity, params) do
    with {:ok, body} <- File.read(path_for(name)),
         {:ok, header, payload} <- split(body),
         :ok <- validate(header, identity, params),
         {:ok, frames, dims} <- claimed_shape(header),
         :ok <- check_length(payload, frames, dims) do
      decode_payload(payload, dims)
    end
  end

  defp split(body) do
    with [@magic, rest] <- :binary.split(body, "\n"),
         [json, payload] <- :binary.split(rest, "\n"),
         {:ok, header} when is_map(header) <- Jason.decode(json) do
      {:ok, header, payload}
    else
      _other -> {:error, :invalid}
    end
  end

  defp validate(header, identity, params) do
    stored_identity = Map.take(header, ["bytes", "mtime", "sha256"])
    stored_params = Map.take(header, Enum.map(Map.keys(params), &Atom.to_string/1))

    cond do
      stored_identity != identity -> {:error, :stale}
      not params_match?(stored_params, params) -> {:error, :stale}
      true -> :ok
    end
  end

  defp claimed_shape(%{"frames" => frames, "dims" => dims})
       when is_integer(frames) and frames >= 0 and is_integer(dims) and dims > 0 do
    {:ok, frames, dims}
  end

  # Zero dimensions is only coherent for zero frames; the other way round would
  # decode a file claiming 30,000 frames into an empty sequence.
  defp claimed_shape(%{"frames" => 0, "dims" => 0}), do: {:ok, 0, 0}

  defp claimed_shape(_header), do: {:error, :invalid}

  # The payload's byte length is the arbiter: a truncated or padded file is
  # refused here rather than decoding into a plausible sequence of the wrong
  # length, which is the shape of wrongness this whole module exists to avoid.
  defp check_length(payload, frames, dims) do
    if byte_size(payload) == frames * dims * 8, do: :ok, else: {:error, :invalid}
  end

  defp decode_payload(_payload, 0), do: {:ok, []}

  defp decode_payload(payload, dims) do
    case floats(payload, []) do
      {:ok, values} -> {:ok, Enum.chunk_every(values, dims)}
      :error -> {:error, :invalid}
    end
  end

  defp floats(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  defp floats(<<value::float-64, rest::binary>>, acc), do: floats(rest, [value | acc])
  # Erlang's binary matching refuses NaN and infinity in a float segment, so a
  # corrupted payload lands here instead of becoming a feature vector.
  defp floats(_other, _acc), do: :error

  # ---------------------------------------------------------------------------
  # The source gate. Every public entry point goes through this.
  # ---------------------------------------------------------------------------

  # The same function `Cutup.Index` calls, not the same rules re-typed. Until
  # 08-13 this was a verbatim copy of Index's check; the two never disagreed, and
  # nothing in the suite would have noticed if they had — each store's traversal
  # test exercised only its own copy.
  defp safe_source(source), do: SourceName.safe(source)

  defp path_for(name), do: Path.join(dir(), name <> @ext)
end
