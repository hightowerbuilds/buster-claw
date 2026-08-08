defmodule BusterClaw.Notifications.Cutup.Assemble do
  @moduledoc """
  The assembly engine for cut-up sentences (STUDIO_ROADMAP Part III, Phase A):
  an ordered list of `t:BusterClaw.Notifications.Cutup.Types.cut/0` in, one
  `SoundStudio` clip out.

  Every audio operation here already existed and is already tested —
  `splice/3`, `fade/2`, `normalize/2`, `concat/1`. **This module contributes no
  DSP.** What it contributes is the arithmetic *between* those calls: how far
  outside a reported word boundary to cut, what to do when that reaches past the
  end of the recording, and how a source that appears forty times in one
  sentence gets read once. That arithmetic is where the bugs live, which is why
  it is a module with a test file rather than a pipeline inlined into a verb.

  ## The per-cut pipeline, and why it is in that order

      resolve source → load (cached) → pad → splice → fade → normalize

  **Pad before splice**, because padding is a change to *what to cut*, not a
  change to the cut audio. **Fade before normalize**, because the fade's ramps
  land on true zero and normalize is a single multiplication — `0.0 * k` is
  still zero, so the seams survive, and the clip's *output* peak is the one that
  gets levelled. Normalizing first would level a peak that the fade then pulls
  down, which is the wrong number to match words on.

  ## The defaults, and why these numbers

  - **`pad_ms: 30`** — recognizer word boundaries are approximate, and speech
    co-articulates. A plosive (`p`, `t`, `k`) is a *silence* followed by a
    burst; the closure sits before the reported onset, so cutting at the
    timestamp removes it and the word arrives decapitated. 30 ms recovers the
    onset for ordinary conversational speech. It is deliberately not larger:
    padding is a blunt instrument that cannot tell the previous word's tail from
    this word's head, and past roughly 50 ms you start reliably dragging a
    neighbour's vowel in with every cut. **That is a real cost of the technique,
    not a bug to fix** — the only way to pad without ever catching a neighbour
    is boundaries that do not lie, and those are not on offer.
  - **`fade_ms: 8`** — long enough to stop being a click (a step edge needs a
    couple of milliseconds of ramp before it reads as a shape rather than a
    tick; 8 ms is 176 samples at 22.05 kHz, comfortably past that), short enough
    to be inaudible as an envelope. **It should always stay well below
    `pad_ms`**: the fade is meant to consume padding, not word. Set
    `fade_ms > pad_ms` and the ramp reaches past the padding into the syllable's
    onset, which is exactly the decapitation the padding was there to prevent.
  - **`gap_ms: 60`** — under ~40 ms the words run into each other and the
    sentence reads as one slurred phrase; at 150 ms and up it reads as someone
    dictating a word list. 60 ms is roughly a stop closure: audible as a seam,
    still inside the rhythm of a spoken sentence. Ramshackle means the seams
    show; it does not mean the pacing is broken.
  - **`normalize: true`** — words pulled from different callers, rooms, handsets
    and distances arrive tens of dB apart. Without levelling the sentence is not
    charmingly rough, it is unintelligible: two words are loud and the other six
    are inaudible. Note that `normalize/2` equalizes **peaks**, not perceived
    loudness (its own docs are honest about this), so a breathy word still sits
    quieter than a shouted one even after levelling.

  Only `normalize: false` disables normalizing; any other value keeps the
  default. Negative or non-numeric `pad_ms`/`fade_ms`/`gap_ms` are floored to
  zero rather than refused — there is no sensible interpretation of a negative
  fade, and refusing the whole sentence over it helps nobody.

  ## `concat/1` + explicit silence, not `mixdown/1`

  `mixdown/1` would also work — it takes placements at millisecond offsets and
  fills the gaps with silence, so a sentence is "each cut at its running
  offset". It was rejected for two reasons, both about this specific shape of
  input:

  1. **It is not exact.** `mixdown/1` rounds each placement offset from
     milliseconds independently of the clip lengths, so the joined length is not
     the sum of the pieces — it is the sum of the pieces plus accumulated
     rounding, drifting a sample per cut in whichever direction. `concat/1` is
     byte concatenation: the total is the sum, exactly, and the headline test
     can assert arithmetic rather than a tolerance.
  2. **It is quadratic here.** `mixdown/1` materializes every placement as a
     full-length integer lane (`List.duplicate(0, offset) ++ samples ++ …`) and
     zips them. That is the right shape for a handful of stacked lanes; for a
     forty-word sentence it is forty lanes each as long as the whole sentence.

  Mixing is also simply not what this does — no two cuts are ever meant to sound
  at once, and `mixdown/1`'s summing (and its clipping) is dead weight on a
  strictly sequential join.

  So the gaps are made here, as a zeroed binary of the right length in the
  internal format. That is all PCM16 silence is.

  ## Sources are basenames, and they are read once

  A `source` is a basename inside the Studio's sources folder, resolved through
  `SoundStudio.path_for/1` — whose allowlist is *membership in the directory
  listing*, so raw input is never joined into a path and an index cannot name
  `/etc/passwd`. A cut carrying anything other than a bare basename is refused
  on that ground alone, before it reaches the filesystem.

  Loaded clips are cached for the duration of one `build/2` call, keyed by
  source name. A sentence built out of one voicemail is the normal case, and
  re-reading (and possibly re-*decoding*, via `afconvert`) that file once per
  word would make the cost of a sentence quadratic in the obvious wrong way. The
  cache lives and dies inside the call: two `build/2` calls never share it, so
  there is no staleness to reason about when a source is re-imported.

  Everything past `import_source/1` is in the internal format (PCM16 mono
  22.05 kHz), which is what makes joining clips from a `.wav`, an `.m4a` and an
  `.mp3` a concatenation rather than a conversion.
  """

  alias BusterClaw.Notifications.Cutup.Types
  alias BusterClaw.Notifications.SoundStudio

  @default_pad_ms 30.0
  @default_fade_ms 8.0
  @default_gap_ms 60.0

  @typedoc """
  Why a sentence could not be built. Every one of these names the offending
  input, because the caller is holding a forty-element list and "no" is not an
  answer it can act on.

  - `:empty_selection` — nothing was selected: an empty list, or something that
    is not a list of cuts at all. The house name, matching
    `SoundStudio.splice/3` and `concat/1`.
  - `{:invalid_cut, cut}` — the map is not a cut: a missing `source`, or times
    that are not numbers.
  - `{:invalid_span, cut}` — `end_ms <= start_ms`. `splice/3` refuses these
    with a bare `:empty_selection`, which for one bad word in a long sentence
    would look exactly like "you selected nothing" and send the reader hunting
    in the wrong place.
  - `{:span_outside_clip, cut}` — well-formed times that land wholly past the
    end (or before the start) of the source. Distinct from `:invalid_span`
    because the fix is different: the times are fine, the index is stale or
    points at the wrong file.
  - `{:source_not_found, source}` — no such basename in the sources folder.
  - `{:unreadable_source, source, reason}` — the file is there but did not come
    back as audio. `reason` is `import_source/1`'s (`:no_decoder`,
    `:unsupported_source`, …), kept because "the system decoder is missing" and
    "this file is not audio" need different responses from the operator.
  """
  @type error ::
          :empty_selection
          | {:invalid_cut, map()}
          | {:invalid_span, map()}
          | {:span_outside_clip, map()}
          | {:source_not_found, String.t()}
          | {:unreadable_source, String.t(), term()}

  @typep settings :: %{
           pad_ms: float(),
           fade_ms: float(),
           gap_ms: float(),
           normalize: boolean()
         }

  @doc """
  Build one clip from an ordered list of cuts.

  Cuts are rendered in the order given — this is a sentence, so order is the
  content — and joined with `gap_ms` of silence between consecutive cuts. The
  result is a clip in the internal format, ready for `SoundStudio.write/2` or
  `SoundStudio.save/2`; nothing is written to disk here.

  Fails on the first bad cut rather than skipping it. A sentence with a word
  silently missing is worse than no sentence: it is wrong in a way nobody
  notices until they listen.

      build([%{source: "voicemail-03.wav", start_ms: 1240.0, end_ms: 1480.0}], gap_ms: 90)

  See `t:error/0` for what can come back.
  """
  @spec build([Types.cut()], Types.assemble_opts()) ::
          {:ok, SoundStudio.t()} | {:error, error()}
  def build(cuts, opts \\ [])

  def build([], _opts), do: {:error, :empty_selection}

  def build(cuts, opts) when is_list(cuts) do
    settings = settings(opts)

    case render_cuts(cuts, settings) do
      {:ok, pieces} -> pieces |> interleave(settings.gap_ms) |> SoundStudio.concat()
      {:error, _reason} = error -> error
    end
  end

  def build(_cuts, _opts), do: {:error, :empty_selection}

  # ---------------------------------------------------------------------------
  # Options
  # ---------------------------------------------------------------------------

  @spec settings(Types.assemble_opts()) :: settings()
  defp settings(opts) when is_list(opts) do
    %{
      pad_ms: milliseconds(opts, :pad_ms, @default_pad_ms),
      fade_ms: milliseconds(opts, :fade_ms, @default_fade_ms),
      gap_ms: milliseconds(opts, :gap_ms, @default_gap_ms),
      normalize: Keyword.get(opts, :normalize, true) != false
    }
  end

  defp settings(_opts), do: settings([])

  defp milliseconds(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_number(value) and value > 0 -> value / 1
      _other -> 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # Rendering each cut, threading the source cache
  # ---------------------------------------------------------------------------

  # The accumulator is a 3-tuple so that it can never be confused with the
  # 2-tuple `{:error, reason}` a halt carries — a distinction a 2-tuple
  # accumulator would lose, silently, by matching the error as `{done, cache}`.
  defp render_cuts(cuts, settings) do
    cuts
    |> Enum.reduce_while({:ok, [], %{}}, fn cut, {:ok, done, cache} ->
      case render_cut(cut, settings, cache) do
        {:ok, clip, cache} -> {:cont, {:ok, [clip | done], cache}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, done, _cache} -> {:ok, Enum.reverse(done)}
      {:error, _reason} = error -> error
    end
  end

  defp render_cut(cut, settings, cache) do
    with :ok <- validate(cut),
         {:ok, clip, cache} <- load(cut.source, cache),
         {:ok, spliced} <- pad_and_splice(clip, cut, settings.pad_ms) do
      {:ok, shape(spliced, settings), cache}
    end
  end

  # A cut is a shape and a span, and they fail for different reasons: a map
  # missing `source` came from the wrong producer, while `end_ms <= start_ms`
  # came from a real index with a bad entry in it.
  defp validate(%{source: source, start_ms: from, end_ms: to} = cut)
       when is_binary(source) and is_number(from) and is_number(to) do
    if to > from, do: :ok, else: {:error, {:invalid_span, cut}}
  end

  defp validate(cut), do: {:error, {:invalid_cut, cut}}

  # ---------------------------------------------------------------------------
  # Loading sources
  # ---------------------------------------------------------------------------

  defp load(source, cache) do
    case Map.fetch(cache, source) do
      {:ok, clip} -> {:ok, clip, cache}
      :error -> load_from_disk(source, cache)
    end
  end

  defp load_from_disk(source, cache) do
    with {:ok, path} <- resolve(source),
         {:ok, clip} <- read_internal(source, path) do
      {:ok, clip, Map.put(cache, source, clip)}
    end
  end

  # `path_for/1`'s allowlist is already membership in the directory listing, so
  # a traversal can never resolve. The basename check in front of it is not
  # redundant defence so much as a *statement*: this function takes a name, and
  # anything path-shaped is rejected as a name rather than sanitized into one.
  defp resolve(source) do
    if Path.basename(source) == source do
      found_or_missing(SoundStudio.path_for(source), source)
    else
      {:error, {:source_not_found, source}}
    end
  end

  defp found_or_missing(nil, source), do: {:error, {:source_not_found, source}}
  defp found_or_missing(path, _source), do: {:ok, path}

  # `import_source/1` is the single normalizing door: a `.wav` already in the
  # internal format comes back untouched, anything else goes through afconvert
  # and comes back resampled and downmixed. The `internal?/1` check after it is
  # belt and braces — `fade/2` and `normalize/2` only accept 16-bit clips, and a
  # FunctionClauseError forty words in is not an answer.
  defp read_internal(source, path) do
    case SoundStudio.import_source(path) do
      {:ok, clip} -> check_format(clip, source)
      {:error, reason} -> {:error, {:unreadable_source, source, reason}}
    end
  end

  defp check_format(clip, source) do
    if SoundStudio.internal?(clip) do
      {:ok, clip}
    else
      {:error, {:unreadable_source, source, :format_mismatch}}
    end
  end

  # ---------------------------------------------------------------------------
  # Padding, splicing, shaping
  # ---------------------------------------------------------------------------

  # Padding is clamped to the clip, never refused. A word at 0 ms is the most
  # ordinary thing in a recording — somebody started talking before the beep —
  # and a cut-up engine that errored on it would be useless on exactly the
  # material it exists for. `splice/3` clamps too; doing it here as well is what
  # lets a span that lands *wholly* outside the clip be named as such instead of
  # arriving as a bare `:empty_selection`.
  defp pad_and_splice(clip, cut, pad_ms) do
    limit = SoundStudio.duration_ms(clip)
    from = max(0.0, cut.start_ms - pad_ms)
    to = min(limit, cut.end_ms + pad_ms)

    case SoundStudio.splice(clip, from, to) do
      {:ok, spliced} -> {:ok, spliced}
      {:error, :empty_selection} -> {:error, {:span_outside_clip, cut}}
    end
  end

  defp shape(clip, settings) do
    clip
    |> SoundStudio.fade(in_ms: settings.fade_ms, out_ms: settings.fade_ms)
    |> maybe_normalize(settings.normalize)
  end

  defp maybe_normalize(clip, true), do: SoundStudio.normalize(clip)
  defp maybe_normalize(clip, false), do: clip

  # ---------------------------------------------------------------------------
  # Joining
  # ---------------------------------------------------------------------------

  defp interleave(pieces, gap_ms) do
    case silence(gap_ms) do
      nil -> pieces
      gap -> Enum.intersperse(pieces, gap)
    end
  end

  # PCM16 silence is a zeroed binary of the right length; there is nothing more
  # to it, and reaching for the synthesizer to make one would be a dependency
  # bought for `:binary.copy/2`. Rounding matches `SoundStudio`'s own
  # ms→samples conversion so that a gap and a splice of the same length produce
  # the same sample count.
  defp silence(gap_ms) when gap_ms > 0 do
    {rate, channels, bits} = SoundStudio.internal_format()
    frames = round(gap_ms * rate / 1000)
    bytes = frames * div(bits, 8) * channels

    if bytes > 0 do
      %SoundStudio{
        sample_rate: rate,
        channels: channels,
        bits: bits,
        data: :binary.copy(<<0>>, bytes)
      }
    end
  end

  defp silence(_gap_ms), do: nil
end
