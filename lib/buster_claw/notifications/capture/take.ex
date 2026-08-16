defmodule BusterClaw.Notifications.Capture.Take do
  @moduledoc """
  Turning captured PCM into a studio source — the server half of the in-app
  recorder (`STUDIO_ROADMAP` V.7).

  The browser holds the microphone and this module holds the file format. That
  split is V.7's third reason for choosing an AudioWorklet over `MediaRecorder`,
  stated as code: *"we already have the encoder"*. `SoundStudio.write/2` has
  produced every WAV this app has ever written and is pinned by a byte-for-byte
  round-trip test, so the recorder ships raw `Float32` frames and lets tested
  Elixir make the file rather than growing a second WAV encoder in JavaScript
  that could disagree with the first.

  ## What arrives, and why it is floats

  An `AudioWorkletProcessor` hands back `Float32` samples in `[-1.0, 1.0]`,
  identically in WKWebView and in Chrome. `MediaRecorder` would have handed back
  MP4/AAC in one host and WebM/Opus in the other — both lossy, both needing a
  decoder, and **the two hosts would disagree**, which is intolerable for a
  corpus whose whole purpose is comparing takes of the same word.

  So the wire format is a base64 `Float32` little-endian buffer plus the sample
  rate the device actually ran at. Nothing is resampled here: V.7's policy is to
  capture and archive at the device's native rate, because downsampling is lossy
  and irreversible and the masters are the only way back.

  ## Clipping is detected, never repaired

  A float sample at or beyond ±1.0 means the converter ran out of range **before
  the signal reached the browser**. No amount of downstream gain recovers it —
  the waveform's top is already flat. `decode/2` therefore reports `clipped?` and
  the peak, and the caller refuses the take at the door rather than letting it be
  discovered later, in a splice, as a click.

  This is the one measurement worth taking seriously here: `sound_normalize`
  targets ≈ −1 dBFS and is **peak**-based, so it will happily scale a clipped
  take to full scale and call it done.

  ## One word and a whole sentence are different KINDS of take

  `index_for/3` branches on how many words the text has, and the difference is
  not cosmetic — it is the difference between a measurement and a guess:

  | Recorded | Origin | Boundaries |
  |---|---|---|
  | one word | `:manual`, confidence 1.0 | the file — the clip **is** the word |
  | a sentence | `:aligned`, capped below 1.0 | `Cutup.Align` divides the text over `Cutup.Vad`'s speech spans |

  **The one-word path is the only thing in this app that produces `:manual`
  takes.** Every one of the 655 takes in the voicemail corpus is `:aligned`,
  because nobody ever marked a boundary by ear. A word recorded deliberately, for
  itself, is different in kind: there is nothing to estimate, so nothing the
  aligner can later second-guess.

  **The sentence path is worth more per minute and worth less per word.** It is
  how a corpus actually gets built — reading is faster than saying single words,
  and V.8's donor session is exactly this at scale — but every boundary inside it
  is proportional arithmetic. Both belong; conflating them would let a guess
  inherit a measurement's confidence.
  """

  alias BusterClaw.Notifications.Cutup.Align
  alias BusterClaw.Notifications.Cutup.Bank
  alias BusterClaw.Notifications.Cutup.Index
  alias BusterClaw.Notifications.Cutup.Vad
  alias BusterClaw.Notifications.SoundStudio

  # Int16 is the studio's working depth: `SoundStudio.peak/1` implements only
  # `bits: 16`, every synthesized chime is 16-bit, and the corpus is 16-bit.
  # Capturing at a depth nothing downstream reads would be a private format.
  @bits 16
  @channels 1

  # Below this a "recording" is the microphone being absent rather than quiet.
  # `Commands.SoundCapture` already refuses digital silence from the `ffmpeg`
  # path for the TCC reason; the browser path can fail the same way when a
  # device is muted in System Settings, and the operator deserves the same
  # sentence rather than a file full of zeros.
  @silence_peak 0.0001

  # A sample rate the hardware could not plausibly have produced means the
  # caller's metadata is wrong, and a wrong rate is unrecoverable: it is not
  # stored in the samples, so the file plays at the wrong speed forever.
  @min_rate 8_000
  @max_rate 192_000

  @typedoc "A decoded take: the clip, and what measuring it found."
  @type t :: %{
          clip: SoundStudio.t(),
          peak: float(),
          clipped?: boolean(),
          duration_ms: float(),
          sample_rate: pos_integer()
        }

  @typedoc "Why a take was refused. Returned, never raised."
  @type error :: :invalid_pcm | :invalid_sample_rate | :empty_take | :silent_take

  @doc """
  Decode a base64 `Float32` little-endian buffer into a studio clip.

  Returns the clip alongside the three numbers the recorder must surface: the
  peak as a fraction of full scale, whether it clipped, and how long it is.

  Refuses an empty buffer (`:empty_take`) and one that is entirely, or nearly,
  digital silence (`:silent_take`) — see the moduledoc on why silence is a
  failure rather than a quiet success.
  """
  @spec decode(term(), term()) :: {:ok, t()} | {:error, error()}
  def decode(pcm, sample_rate) when is_binary(pcm) do
    with {:ok, rate} <- rate(sample_rate),
         {:ok, raw} <- base64(pcm),
         {:ok, floats} <- floats(raw) do
      measure(floats, rate)
    end
  end

  def decode(_pcm, _sample_rate), do: {:error, :invalid_pcm}

  # Build the index that makes a recorded take findable.
  #
  # One word or a whole sentence — the branch and its reasoning are in the
  # moduledoc, and the short version is that a single word's boundary is the file
  # (a measurement) while a sentence's interior boundaries are `Cutup.Align`
  # dividing the text over the speech it found (a guess, and labelled as one).
  #
  # `bank` is validated by `Index.build/3`, which refuses a name that is not on
  # the roster. That refusal is the point: filing a contributor's take into the
  # wrong voice is the failure `Cutup.Bank` exists to prevent.
  #
  # PRIVATE since 08-16. It was public with no caller outside this module — a
  # shipped API nobody asked for. `store/3` is the whole surface.
  defp index_for(source, text, %{duration_ms: duration_ms, clip: clip}) when is_binary(text) do
    case words_in(text) do
      [] ->
        {:error, :invalid_index}

      [single] ->
        # ONE word: the clip is the word, so the boundary is the file and no
        # alignment runs. `:manual` at confidence 1.0 — a person said this word
        # deliberately, which is a different kind of fact from a guess.
        Index.build(
          source,
          [%{text: single, start_ms: 0.0, end_ms: duration_ms, confidence: 1.0}],
          origin: :manual,
          bank: Bank.active()
        )

      _many ->
        # A SENTENCE: the words are known, the boundaries are not. That is
        # exactly what `Cutup.Align` is for — VAD finds the speech, and the
        # transcript is divided across it by syllable weight. `:aligned`, and
        # capped below 1.0 by `Align` itself, because these timings are a
        # proportional guess and must never be mistaken for a marked boundary.
        Index.build(source, aligned_words(text, clip), origin: :aligned, bank: Bank.active())
    end
  end

  defp index_for(_source, _text, _take), do: {:error, :invalid_index}

  # `Vad.energy_profile/2` is passed to `align/3` so interior boundaries snap to
  # the quiet moments near them rather than landing wherever arithmetic put them.
  # Without it the division is uniform and the seams fall mid-phoneme.
  defp aligned_words(text, clip) do
    Align.align(text, Vad.spans(clip), energy: Vad.energy_profile(clip))
  end

  defp words_in(text) do
    text
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(&Index.normalize_word/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc "The studio's working audio depth and channel count, for callers reporting format."
  @spec format() :: %{bits: pos_integer(), channels: pos_integer()}
  def format, do: %{bits: @bits, channels: @channels}

  @doc """
  Write a decoded take into `sounds/studio/` and index it if its word is known.

  Returns the source basename it was stored as.

  **A name collision is refused, never resolved** (`:name_taken`). V.7 states the
  rule and the reason in one line: *"a recording is unrepeatable; a name
  collision prompts, always."* Auto-suffixing would be the friendlier-looking
  choice and the wrong one — the operator who just recorded take three of
  `harbor` and sees it saved as `harbor-2` has no way to know which file is which
  voice, and the corpus quietly grows names nobody chose.

  Indexing is best-effort in one specific direction: **the audio is written
  first**, and an index that fails to build leaves the WAV on disk rather than
  discarding a take that cannot be re-recorded. The caller learns the source name
  either way; a missing index is a re-index, a discarded take is gone.
  """
  @spec store(t(), term(), term()) :: {:ok, String.t()} | {:error, term()}
  def store(%{clip: clip} = take, name, word) do
    with :ok <- refuse_clipped(take),
         {:ok, source} <- source_name(name, word),
         :ok <- File.mkdir_p(SoundStudio.dir()),
         :ok <- SoundStudio.write(clip, Path.join(SoundStudio.dir(), source)) do
      index(source, word, take)
      {:ok, source}
    end
  end

  # The name is the operator's if they gave one, and derived from the word if
  # they did not. `AudioName.safe_name/1` owns the rules — it is the same gate
  # every other write into this directory passes through, and a second one here
  # would be a copy that can weaken on one side.
  #
  # ## A collision means different things depending on who chose the name
  #
  # This function refused BOTH cases until 08-16, and half of that was wrong.
  # The rule it was enforcing is V.7's, and it is still right: *"a recording is
  # unrepeatable; a name collision prompts, always."* What was wrong was reading
  # a derived name as a chosen one.
  #
  # - **The operator typed a name** → refuse (`:name_taken`). They asked for a
  #   specific file, one exists, and silently writing beside it hides that.
  # - **The name came from the word** → number up. They asked to record *harbor*,
  #   not to create `harbor.wav`; a second take of a word is the whole point of
  #   a corpus, and refusing it made the recorder able to capture each word
  #   exactly once. Nothing is overwritten — `harbor-2.wav` is a new file.
  #
  # The earlier comment argued auto-suffixing was wrong because the operator
  # "has no way to know which file is which voice". That was true when nothing
  # listed takes per word. The Voice Library does, so the objection is spent.
  defp source_name(name, word) do
    cond do
      is_binary(name) and String.trim(name) != "" ->
        chosen = BusterClaw.AudioName.safe_name(ensure_wav(String.trim(name)))
        if exists?(chosen), do: {:error, :name_taken}, else: {:ok, chosen}

      is_binary(word) and derived_name(word) != "" ->
        {:ok, next_free(BusterClaw.AudioName.safe_name(ensure_wav(derived_name(word))))}

      true ->
        {:error, :name_required}
    end
  end

  # `harbor.wav`, then `harbor-2.wav`, `harbor-3.wav`. Bounded so a corrupt
  # directory cannot spin here; 999 takes of one word is far past the point where
  # the answer is "something else is wrong".
  defp next_free(source) do
    if exists?(source) do
      stem = Path.rootname(source)
      ext = Path.extname(source)

      Enum.find_value(2..999, source, fn n ->
        candidate = "#{stem}-#{n}#{ext}"
        if exists?(candidate), do: nil, else: candidate
      end)
    else
      source
    end
  end

  defp exists?(source), do: File.exists?(Path.join(SoundStudio.dir(), source))

  # One word names itself. A SENTENCE names itself from its first four words —
  # long enough to tell two takes apart in a directory listing, short enough to
  # stay a filename. The whole sentence would be a 200-character name that
  # `AudioName.safe_name/1` would then truncate mid-word.
  # Empty when the text has no usable words — checked by the caller, because
  # `AudioName.safe_name/1` turns an unusable stem into `"track"` and a
  # punctuation-only word would otherwise land as `track.wav`.
  defp derived_name(text) do
    text |> words_in() |> Enum.take(4) |> Enum.join("-")
  end

  defp ensure_wav(name) do
    if String.ends_with?(String.downcase(name), ".wav"), do: name, else: name <> ".wav"
  end

  # Refused HERE rather than in `Commands.SoundCapture`, so the rule holds for
  # both callers. The in-app recorder reaches this module directly — a LiveView
  # may not call `Commands.call/3`, which defaults to `caller: :trusted` and
  # would hand a remote browser the full tier (`remote_mode_test.exs` pins that)
  # — so a check that lived in the command would have been absent from the one
  # path that actually records.
  #
  # And refused rather than warned about, because a clipped take is the LOUDEST
  # take of its word: `Cutup.Dtw` ranks on features that clipping inflates, so
  # the broken one would be preferentially chosen for every splice.
  defp refuse_clipped(%{clipped?: true}), do: {:error, :clipped_take}
  defp refuse_clipped(_take), do: :ok

  # Best effort, and deliberately not part of the `with` above — see `store/3`.
  #
  # An index with NO words is never written. `Index.build/3` drops an entry whose
  # text normalizes to nothing (pure punctuation is not a searchable word), so a
  # take recorded for `"!!!"` would otherwise land as a valid, empty index — and
  # `Cutup.Gaps` counts index FILES, so the corpus would report an indexed source
  # containing nothing. An empty index is not a degraded index; it is an index
  # that should not exist.
  defp index(source, word, take) when is_binary(word) do
    case index_for(source, word, take) do
      {:ok, %{words: []}} -> :ok
      {:ok, index} -> Index.save(index)
      {:error, _reason} -> :ok
    end
  end

  defp index(_source, _word, _take), do: :ok

  # ---------------------------------------------------------------------------
  # Decoding
  # ---------------------------------------------------------------------------

  defp rate(value) when is_integer(value) and value >= @min_rate and value <= @max_rate,
    do: {:ok, value}

  defp rate(_value), do: {:error, :invalid_sample_rate}

  defp base64(pcm) do
    case Base.decode64(pcm) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :invalid_pcm}
    end
  end

  # A Float32 buffer is a whole number of 4-byte samples. A trailing partial one
  # means the transfer was truncated, and guessing at it would silently shorten
  # the take — `SoundStudio.parse/1` drops a partial frame for the same reason,
  # but here it indicates a broken upload rather than a quirk of a file.
  defp floats(raw) when byte_size(raw) == 0, do: {:error, :empty_take}

  defp floats(raw) when rem(byte_size(raw), 4) != 0, do: {:error, :invalid_pcm}

  defp floats(raw), do: {:ok, for(<<f::little-float-32 <- raw>>, do: f)}

  defp measure([], _rate), do: {:error, :empty_take}

  defp measure(floats, rate) do
    peak = floats |> Enum.reduce(0.0, &max(abs(&1), &2)) |> Float.round(6)

    if peak < @silence_peak do
      {:error, :silent_take}
    else
      {:ok, take(floats, rate, peak)}
    end
  end

  defp take(floats, rate, peak) do
    data = pcm16(floats)

    clip = %SoundStudio{
      sample_rate: rate,
      channels: @channels,
      bits: @bits,
      data: data
    }

    %{
      clip: clip,
      peak: peak,
      # At or beyond full scale the converter already ran out of range; see the
      # moduledoc. Measured on the FLOATS, before the int16 conversion below
      # clamps them, because clamping is what would hide it.
      clipped?: peak >= 1.0,
      duration_ms: SoundStudio.duration_ms(clip),
      sample_rate: rate
    }
  end

  # Float [-1.0, 1.0] to signed 16-bit little-endian.
  #
  # Scaling by 32_767 rather than 32_768 keeps +1.0 inside the positive rail
  # instead of wrapping to the negative one. Saturation is `SoundStudio`'s —
  # this module had its own copy until 08-16, which made three implementations
  # of "what is the loudest sample" for a value where disagreeing is audible.
  defp pcm16(floats) do
    for f <- floats, into: <<>> do
      <<SoundStudio.clamp16(f * 32_767)::little-signed-16>>
    end
  end
end
