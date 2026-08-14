defmodule BusterClaw.Notifications.Cutup.Vad do
  @moduledoc """
  Voice-activity detection over PCM16 (STUDIO_ROADMAP Part III, phase V.3, which
  subsumes Part II's Phase D): windowed RMS plus zero-crossing rate, in pure
  Elixir, with no dependency and no FFT.

  **It is an energy detector, not a speech classifier.** It finds where
  *something happens* — a door slam, a dog, a dial tone and a fricative are all
  "activity", and nothing here can tell them apart. That is not a shortcoming to
  be apologised for: it is precisely what the operator asked for when they asked
  for "words *or sounds*". Naming it "voice" activity detection is the standard
  term of art, and the standard term of art is a slight lie.

  ## Its two customers

  1. **Word boundaries for the cut-up.** A DTW hit reports a warped span whose
     edges land wherever the warping path happened to end, which is routinely a
     few frames inside the word. Snapping that hit outward to the nearest span
     edge found here gives a cut that starts at silence rather than mid-phoneme.
  2. **"Or sounds."** No template, no recogniser, no transcript — just the
     honest question of where the recording stops being quiet.

  And a third, immediately: `trim/2` strips leading and trailing silence off any
  clip, which the Studio wants whether or not a recogniser ever exists.

  ## The two measurements, and why one is not enough

  Every frame gets **short-time RMS** and **zero-crossing rate** (the fraction of
  adjacent sample pairs that change sign).

  - **Voiced speech** — vowels, nasals, `m`/`n`/`l`/`r` — is high-energy and
    low-ZCR. A vowel is a periodic buzz at 80–300 Hz; at 22.05 kHz that is a ZCR
    of roughly 0.01–0.05.
  - **Unvoiced fricatives** — `s`, `f`, `sh`, `th` — are the opposite: they are
    turbulence, not phonation. They carry **10–30 dB less energy** than the vowel
    beside them and their energy sits up at 4–8 kHz, so their ZCR is an order of
    magnitude higher (0.3–0.6).

  An energy-only detector therefore does not merely score fricatives lower — it
  systematically **clips the front off every word that begins with one**. "Six",
  "stop", "friday", "shut" all arrive with their onset amputated, and in a
  feature whose entire output is spliced-together words, that is not a metric
  regression, it is an audible defect in every assembled sentence.

  ZCR is what buys those onsets back. **Precisely what it does here**: it lowers
  the energy gate from `+12 dB` over the noise floor to `+4 dB`, but only for
  frames that are broadband. What ZCR emphatically cannot do is separate a
  fricative from the noise floor — **wideband noise has the highest ZCR of
  anything in the recording** — so the ZCR branch always carries its own energy
  gate. ZCR alone would mark room tone as speech.

  ## Thresholding: adaptive, relative to a measured noise floor

  A fixed absolute threshold cannot work. The corpus is telephony: different
  handsets, different distances from the mouth, different carriers, different
  rooms. The level of a word varies by tens of dB between two calls, and any
  constant tuned on one is wrong for the other.

  So the threshold is estimated from the recording itself:

      noise_floor = 10th percentile of frame RMS   (clamped, see below)
      enter       = noise_floor x 4.0    (+12 dB)
      leave       = noise_floor x 2.0    (+6 dB)
      fric_enter  = noise_floor x 1.6    (+4 dB)  -- with ZCR >= 0.25
      fric_leave  = noise_floor x 1.3    (+2.3 dB) -- with ZCR >= 0.18

  **Why the 10th percentile and not the minimum:** the minimum is one frame and
  one frame is an outlier. A percentile is what makes the estimate survive a
  single anomalously dead frame, and it holds as long as at least a tenth of the
  recording is not speech — true of voicemail, which is mostly pauses.

  **Why a multiplicative margin rather than a fraction of the dynamic range:**
  a range-relative rule (`floor + 0.3 x (p95 - floor)`) is exactly scale-free,
  which is attractive, but it makes the threshold depend on *how much* of the
  clip is loud. A clip that is 3% activity has its p95 sitting in the noise, the
  range collapses, and the detector finds either everything or nothing. A margin
  over the floor depends only on the noise, which is the stationary part.

  **Why linear RMS and not dB:** a digitally-silent floor is `-inf` dB. Every
  dB-relative margin degenerates there; in linear terms it is simply zero.

  **The one absolute constant, and why it is unavoidable:** a synthesised clip,
  or a carrier that gates its silence, has a noise floor of *exactly zero*, and
  twelve decibels above zero is zero. So the floor is clamped up to
  `#{inspect(3.0e-4)}` RMS (about -70 dBFS, ~10 LSB of int16) — below any real
  recording's noise floor, above dither. Zero has no scale; something has to
  supply one.

  ## Hysteresis, and the run rule

  A single threshold chatters: a frame at the boundary crosses back and forth and
  one word becomes six spans. So the gates come in pairs (a Schmitt trigger), and
  the span rule is stated over runs rather than as a state machine:

  > A span is a maximal run of frames above the **leave** gates that contains at
  > least one frame above the **enter** gates.

  That is hysteresis in both directions at once — the run extends backward into
  the quiet onset of the word and forward through its decay, and neither is a
  special case. `enter` implies `hold` by construction, so the rule is total.

  ## Then two smoothing rules, applied in this order

  1. **Merge spans separated by less than `:min_silence_ms`.** This one is not
     polish. A voiceless stop (`t`, `k`, `p`) *is a silence* — 50–100 ms of
     closure while the articulators seal, before the burst. Without this rule an
     unsmoothed detector shatters every word containing one: "**t**icket" becomes
     three spans, and the cut-up cuts inside the word.
  2. **Then reject spans shorter than `:min_span_ms`.** Merge first, reject
     second, deliberately: two 40 ms halves of "cat" should merge into one 100 ms
     span, not be discarded as two blips.

  ## Frame arithmetic

  25 ms frames at a 10 ms hop, both pinned in `Cutup.Types` and read from there at
  compile time — the analysis frame is the clock the whole pipeline shares. Frame `i` starts at exactly
  `i * 10.0 ms` (the sample offset is rounded from that, never accumulated, so
  there is no drift at 22.05 kHz where the hop is 220.5 samples).

  A span therefore reports `first * 10.0` to `last * 10.0 + 25.0`: **the frame's
  full extent, not its start**. A boundary is accurate to roughly one frame, and
  the reported edges lean outward — which is the safe direction for a caller that
  is about to cut.

  Each frame's mean is removed before measuring. A DC offset from a handset's
  ADC otherwise reads as constant energy that no threshold can get under, and
  biases ZCR toward zero for exactly the signal that needed it most.

  ## What this will get wrong

  - **A clip with no silence in it has no noise floor to measure.** The 10th
    percentile lands on speech, the threshold lands 12 dB above speech, and the
    result is the loudest tenth rather than "all of it". Feed it a recording with
    some room tone at either end, or pass `:threshold` explicitly.
  - **A loud non-speech event is activity**, and it should be — but a caller that
    wanted *words* will get the door slam too.
  - **Music, hold tone and hum are activity.** Sustained, periodic, energetic:
    indistinguishable from a vowel by these two numbers.
  - **A whispered word may be missed entirely.** Whispering is all fricative
    energy; if it sits under +4 dB over the floor, nothing here will find it.
  - **8 kHz telephony bands out everything above 3.4 kHz**, which is most of a
    fricative's energy. ZCR still rises, but less, and the ZCR gate is the first
    number that will want retuning against the real corpus.

  When a result looks wrong, `energy_profile/2` is the answer: it returns the
  per-frame numbers *and the computed thresholds*, so the question "why did it
  think that" has an answer that is not a rebuild.
  """

  alias BusterClaw.Notifications.Cutup.Types
  alias BusterClaw.Notifications.SoundStudio

  # The analysis clock, read from `Cutup.Types` at COMPILE TIME — the same two
  # numbers `Signal` and `Dtw` read, not a restatement of them. A template framed
  # at one hop and a recording framed at another cannot be compared at all, and
  # three literals agreeing by inspection is not a mechanism. Reading into an
  # attribute keeps them literals in the per-frame arithmetic below, so nothing
  # here calls out per frame.
  @frame_ms Types.frame_ms()
  @hop_ms Types.hop_ms()

  # Where the noise floor is read from the RMS distribution, and the reference
  # for "loud" — reported for inspection, deliberately not used in the gates.
  @floor_pct 0.10
  @loud_pct 0.95

  # The smallest RMS we are willing to call sound (~-70 dBFS). Only ever binds
  # when the floor is literally zero; see the moduledoc.
  @noise_epsilon 3.0e-4

  # Margins over the floor. The pair is the Schmitt trigger; the fricative pair
  # is the same trigger with a lower energy gate and a ZCR requirement.
  @enter_gain 4.0
  @leave_gain 2.0
  @fricative_enter_gain 1.6
  @fricative_leave_gain 1.3

  # ZCR is a *rate* — dimensionless, and already comparable between a cheap
  # handset and a good one — so unlike energy it takes fixed thresholds. Voiced
  # speech sits under ~0.1 at 22.05 kHz; fricatives run 0.3-0.6.
  @zcr_enter 0.25
  @zcr_leave 0.18

  # 60 ms is a bit over two hops of real span. Under ~40 ms you keep every lip
  # smack, click and packet glitch; over ~150 ms you start throwing away real
  # short sounds, and "or sounds" is half the point of this module.
  @default_min_span_ms 60.0

  # 120 ms comfortably covers a voiceless stop's closure (50-100 ms) plus the
  # frame-edge slop, and stays under a deliberate inter-word pause (200 ms+), so
  # words survive intact while phrases still separate.
  @default_min_silence_ms 120.0

  # `trim/2` keeps a margin, for the same reason `Assemble` pads a cut: the span
  # edge is accurate to about a frame, and a trim that lands a millisecond late
  # takes the attack of the first word with it. 30 ms matches `Assemble`'s
  # `pad_ms` so a trimmed clip and a cut word have the same manners.
  @default_trim_pad_ms 30.0

  @typedoc """
  How to detect.

  - `:min_span_ms` — reject anything shorter, measured on the *reported* span
    (so a caller rejects on the same number they can see).
  - `:min_silence_ms` — gaps shorter than this are not gaps. The stop-consonant
    rule; see the moduledoc.
  - `:threshold` — `:auto` (the default, estimated per recording) or an absolute
    RMS in 0.0..1.0 for the enter gate, from which the other three derive at the
    same ratios. Pass a number only when you have measured one with
    `energy_profile/2`; a constant carried between two recordings is the failure
    this module exists to avoid.
  """
  @type opts :: [
          min_span_ms: number(),
          min_silence_ms: number(),
          threshold: number() | :auto
        ]

  @typedoc "The gates in force, as computed for one recording."
  @type thresholds :: %{
          mode: :auto | :fixed,
          noise_floor: float(),
          loud: float(),
          enter: float(),
          leave: float(),
          fricative_enter: float(),
          fricative_leave: float(),
          zcr_enter: float(),
          zcr_leave: float()
        }

  @typedoc "One frame's measurements and its verdict against the gates."
  @type frame_measure :: %{
          index: non_neg_integer(),
          start_ms: float(),
          end_ms: float(),
          rms: float(),
          zcr: float(),
          enter?: boolean(),
          hold?: boolean()
        }

  @typedoc "Everything the detector reasoned about, verdict included."
  @type profile :: %{
          frame_ms: float(),
          hop_ms: float(),
          frame_count: non_neg_integer(),
          duration_ms: float(),
          thresholds: thresholds(),
          frames: [frame_measure()]
        }

  # ---------------------------------------------------------------------------
  # The public surface
  # ---------------------------------------------------------------------------

  @doc """
  Contiguous regions above the noise floor, in time order.

  Returns `t:BusterClaw.Notifications.Cutup.Types.span/0` values, whose `:frames`
  is how many analysis frames the span covers — enough for a caller to reject
  something too short to be a word without re-running anything.

  A clip that is not the Studio's internal format (PCM16 mono) yields no spans:
  `SoundStudio.import_source/1` is the single door that normalises, and reporting
  offsets computed in the wrong time base would be worse than reporting nothing.
  """
  @spec spans(SoundStudio.t(), opts()) :: [Types.span()]
  def spans(clip, opts \\ [])

  def spans(%SoundStudio{} = clip, opts) when is_list(opts) do
    clip
    |> energy_profile(opts)
    |> profile_spans(opts)
  end

  @doc """
  The complement of `spans/2` within the clip — every region *not* above the
  floor, including the leading and trailing ones.

  Useful for two things: finding where a clip may be cut without landing inside a
  word, and trimming (which is `silences/2` at the two ends, and is `trim/2`).

  `:frames` here is the region's length in hops rather than a count of measured
  frames, because a gap shorter than one frame is still a gap; it is floored at
  one so the value stays a `pos_integer` as the type requires.
  """
  @spec silences(SoundStudio.t(), opts()) :: [Types.span()]
  def silences(clip, opts \\ [])

  def silences(%SoundStudio{} = clip, opts) when is_list(opts) do
    clip
    |> spans(opts)
    |> gaps(SoundStudio.duration_ms(clip))
  end

  @doc """
  Strip leading and trailing silence, keeping `:pad_ms` (default
  #{trunc(@default_trim_pad_ms)} ms) of it on each side.

  **A clip with no detected activity is returned unchanged, not emptied.** A trim
  that deletes the operator's audio because the detector had a bad day is the
  worst failure available to this module, and "no activity" is the exact
  condition under which the detector is least sure of itself.

  Only the ends are cut. Silence *inside* the clip is left alone — removing it
  would be an edit nobody asked for, and `spans/2` is there for a caller that
  wants the pieces.
  """
  @spec trim(SoundStudio.t(), opts()) :: SoundStudio.t()
  def trim(clip, opts \\ [])

  def trim(%SoundStudio{} = clip, opts) when is_list(opts) do
    pad = opt_ms(opts, :pad_ms, @default_trim_pad_ms)

    case spans(clip, opts) do
      [] -> clip
      found -> cut(clip, List.first(found).start_ms - pad, List.last(found).end_ms + pad)
    end
  end

  @doc """
  The per-frame measurements and the gates they were judged against.

  This is the module's answer to "why did it decide that". A verdict alone is
  untunable: the numbers, the computed thresholds, and the frame clock together
  are what let a person (or a test) see that the noise floor was estimated 20 dB
  too high because the caller never stopped talking.

  `splice/3` from these numbers is exact: frame `i` starts at `i * hop_ms`.
  """
  @spec energy_profile(SoundStudio.t(), opts()) :: profile()
  def energy_profile(clip, opts \\ [])

  def energy_profile(%SoundStudio{bits: 16, channels: 1} = clip, opts) when is_list(opts) do
    measured = measure_frames(clip)
    gates = thresholds(measured, opts)

    %{
      frame_ms: @frame_ms,
      hop_ms: @hop_ms,
      frame_count: length(measured),
      duration_ms: SoundStudio.duration_ms(clip),
      thresholds: gates,
      frames: Enum.map(measured, &classify(&1, gates))
    }
  end

  # Not internal format: report an empty analysis rather than measuring bytes
  # whose layout we have not established. `duration_ms` is 0.0 rather than the
  # clip's real length precisely so nobody mistakes this for an analysis.
  def energy_profile(%SoundStudio{}, opts) when is_list(opts) do
    %{
      frame_ms: @frame_ms,
      hop_ms: @hop_ms,
      frame_count: 0,
      duration_ms: 0.0,
      thresholds: thresholds([], opts),
      frames: []
    }
  end

  # ---------------------------------------------------------------------------
  # Framing and measurement
  # ---------------------------------------------------------------------------

  # Frame starts are rounded from the ms clock rather than stepped by a rounded
  # hop: at 22.05 kHz the hop is 220.5 samples, and stepping by 220 or 221 drifts
  # half a sample per frame — 68 ms of lie over a thirty-second recording.
  defp measure_frames(%SoundStudio{} = clip) do
    total = SoundStudio.sample_count(clip)
    len = frame_len(clip.sample_rate)
    hop = clip.sample_rate * @hop_ms / 1000.0

    if total < len or len < 2 do
      []
    else
      0
      |> Stream.iterate(&(&1 + 1))
      |> Stream.map(fn i -> {i, round(i * hop)} end)
      |> Enum.take_while(fn {_i, start} -> start + len <= total end)
      |> Enum.map(fn {i, start} -> measure(clip.data, i, start, len) end)
    end
  end

  defp frame_len(rate), do: round(rate * @frame_ms / 1000.0)

  defp measure(data, index, start, len) do
    samples =
      for <<s::little-signed-16 <- binary_part(data, start * 2, len * 2)>>, do: s / 32_768.0

    mean = Enum.sum(samples) / len

    {square_sum, crossings, _prev} =
      Enum.reduce(samples, {0.0, 0, 0.0}, fn s, {acc, count, prev} ->
        x = s - mean
        {acc + x * x, count + crossing(x, prev), x}
      end)

    %{
      index: index,
      start_ms: index * @hop_ms,
      end_ms: index * @hop_ms + @frame_ms,
      rms: :math.sqrt(square_sum / len),
      zcr: crossings / (len - 1)
    }
  end

  # A sample of exactly zero is not a crossing in either direction — which is
  # what keeps digital silence at ZCR 0.0 rather than 1.0.
  defp crossing(x, prev) when x * prev < 0.0, do: 1
  defp crossing(_x, _prev), do: 0

  # ---------------------------------------------------------------------------
  # Thresholds
  # ---------------------------------------------------------------------------

  defp thresholds(measured, opts) do
    sorted = measured |> Enum.map(& &1.rms) |> Enum.sort()
    floor = percentile(sorted, @floor_pct)
    loud = percentile(sorted, @loud_pct)

    case Keyword.get(opts, :threshold, :auto) do
      n when is_number(n) and n > 0 ->
        build(:fixed, n * 1.0, n / @enter_gain, floor, loud)

      _auto ->
        build(
          :auto,
          max(floor, @noise_epsilon) * @enter_gain,
          max(floor, @noise_epsilon),
          floor,
          loud
        )
    end
  end

  # Every gate but `enter` derives from `base`, so a caller-supplied absolute
  # threshold gets the same hysteresis ratios the adaptive path uses.
  defp build(mode, enter, base, floor, loud) do
    %{
      mode: mode,
      noise_floor: floor,
      loud: loud,
      enter: enter,
      leave: base * @leave_gain,
      fricative_enter: base * @fricative_enter_gain,
      fricative_leave: base * @fricative_leave_gain,
      zcr_enter: @zcr_enter,
      zcr_leave: @zcr_leave
    }
  end

  # Linear interpolation between the two neighbouring order statistics, so the
  # estimate does not jump as the frame count changes.
  defp percentile([], _p), do: 0.0

  defp percentile(sorted, p) do
    n = length(sorted)
    pos = p * (n - 1)
    lo = trunc(pos)
    hi = min(lo + 1, n - 1)
    frac = pos - lo

    Enum.at(sorted, lo) * (1.0 - frac) + Enum.at(sorted, hi) * frac
  end

  # `enter?` implies `hold?`: every gain on the left of the pair is larger than
  # the one on the right, so the run rule below can never see an entry frame
  # that is not also a hold frame.
  defp classify(frame, gates) do
    Map.merge(frame, %{
      enter?:
        frame.rms >= gates.enter or
          (frame.rms >= gates.fricative_enter and frame.zcr >= gates.zcr_enter),
      hold?:
        frame.rms >= gates.leave or
          (frame.rms >= gates.fricative_leave and frame.zcr >= gates.zcr_leave)
    })
  end

  # ---------------------------------------------------------------------------
  # Spans
  # ---------------------------------------------------------------------------

  defp profile_spans(profile, opts) do
    min_span = opt_ms(opts, :min_span_ms, @default_min_span_ms)

    profile.frames
    |> active_runs()
    |> merge_runs(opt_ms(opts, :min_silence_ms, @default_min_silence_ms))
    |> Enum.map(&to_span/1)
    |> Enum.filter(&(&1.end_ms - &1.start_ms >= min_span))
  end

  # The hysteresis rule, whole: a maximal run above the leave gates that touches
  # the enter gates at least once.
  defp active_runs(frames) do
    frames
    |> Enum.chunk_by(& &1.hold?)
    |> Enum.filter(fn [first | _rest] = run -> first.hold? and Enum.any?(run, & &1.enter?) end)
    |> Enum.map(fn run -> {List.first(run).index, List.last(run).index} end)
  end

  # The gap is measured between the *reported* edges — frame extents, not frame
  # starts — so it is the same number a caller reads off two spans. Adjacent
  # runs separated by one dead frame have a negative gap, which merges.
  defp merge_runs([], _min_silence), do: []

  defp merge_runs([first | rest], min_silence) do
    rest
    |> Enum.reduce([first], fn {start, stop}, [{prev_start, prev_stop} | acc] ->
      if start * @hop_ms - (prev_stop * @hop_ms + @frame_ms) < min_silence do
        [{prev_start, stop} | acc]
      else
        [{start, stop}, {prev_start, prev_stop} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp to_span({first, last}) do
    %{
      start_ms: first * @hop_ms,
      end_ms: last * @hop_ms + @frame_ms,
      frames: last - first + 1
    }
  end

  # [0 .. first span] , [between spans] , [last span .. end]. Zero-length and
  # inverted regions are dropped rather than reported as empty spans.
  defp gaps(spans, duration) do
    edges = [0.0] ++ Enum.flat_map(spans, &[&1.start_ms, &1.end_ms]) ++ [duration]

    edges
    |> Enum.chunk_every(2)
    |> Enum.filter(fn [from, to] -> to - from > 0.0 end)
    |> Enum.map(fn [from, to] ->
      %{start_ms: from, end_ms: to, frames: max(1, trunc((to - from) / @hop_ms))}
    end)
  end

  # ---------------------------------------------------------------------------
  # Plumbing
  # ---------------------------------------------------------------------------

  defp cut(clip, from_ms, to_ms) do
    case SoundStudio.splice(clip, from_ms, to_ms) do
      {:ok, trimmed} -> trimmed
      {:error, _reason} -> clip
    end
  end

  # A negative or non-numeric millisecond option is floored to its default
  # rather than refused: there is no reading of a negative minimum span, and
  # failing a whole trim over one helps nobody.
  defp opt_ms(opts, key, default) do
    case Keyword.get(opts, key, default) do
      n when is_number(n) and n >= 0 -> n * 1.0
      _invalid -> default
    end
  end
end
