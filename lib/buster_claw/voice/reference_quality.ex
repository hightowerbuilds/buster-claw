defmodule BusterClaw.Voice.ReferenceQuality do
  @moduledoc """
  A grade for a reference recording, measured from the audio itself.

  ## What this does and does not claim

  It grades **the recording**, never the clone. Nothing here predicts how much
  the rendered voice will sound like the operator — that would need a measured
  correlation between these numbers and cloning fidelity, and no such
  measurement has been taken. What it does claim is narrower and defensible: a
  clip that is quiet, clipped, mostly silence, or buried in room noise is a
  worse thing to hand an engine than one that is not, and every one of those is
  a number you can read off the samples.

  So the copy the operator sees says "this recording is quiet", not "this will
  sound bad". The first is measured. The second is a guess wearing its clothes.

  ## Why length is a quality signal here and not just a preference

  Cloning conditions on the reference, so its length is paid on **every render**,
  not once. On the operator's Intel i9 a 13.3-second reference pushed a
  five-word line past the renderer's ten-minute ceiling, and the render was
  killed with the work discarded (09-06). Length therefore appears in the grade
  with a cost attached, which is why `:too_long` is a real finding and not
  pedantry about ideal microphone technique.

  ## The thresholds, and where they come from

  They are ordinary audio-engineering hygiene for speech, not tuned constants:

  | Measure | Good | Warn | Why |
  |---|---|---|---|
  | duration | 4–10 s | < 3 s or > 12 s | enough voice to clone; paid every render |
  | peak | −9 to −1 dBFS | < −18 dBFS | headroom without hitting the rail |
  | RMS | −27 to −13 dBFS | < −32 dBFS | broadcast-ish speech loudness |
  | speech ratio | ≥ 0.75 | < 0.6 | silence is length you pay for and learn nothing from |
  | SNR | ≥ 20 dB | < 12 dB | the room versus the voice |
  | clipping | 0 % | > 0.05 % | flat-topped samples are lost waveform |

  A number sitting between the good and warn columns is fine and says nothing.
  Only the warn side produces a note, because a grader that comments on
  everything is a grader nobody reads.

  ## Reading the audio

  `Notifications.SoundStudio.read/1` does the WAV parsing. That module travels
  with the Studio when it is spun out, and `Voice.Reference` already depends on
  it for exactly this reason and says so in its own moduledoc — this adds no new
  coupling, it reuses the one that was already accepted. If the Studio leaves,
  both call sites move together.
  """

  alias BusterClaw.Notifications.SoundStudio

  @frame_ms 20

  # Below this a frame is treated as room rather than voice, whatever the noise
  # floor turns out to be. Without an absolute floor, a recording made in a
  # silent room grades its own faint hiss as speech and reports a speech ratio
  # of 1.0 for a clip that is mostly nothing.
  @absolute_speech_floor_dbfs -50.0

  defstruct [
    :grade,
    :duration_s,
    :speech_ratio,
    :peak_dbfs,
    :rms_dbfs,
    :snr_db,
    :clipped_pct,
    :sample_rate,
    notes: []
  ]

  @type severity :: :bad | :warn
  @type note :: %{severity: severity(), text: String.t(), fix: String.t()}

  @type t :: %__MODULE__{
          grade: :good | :fair | :poor,
          duration_s: float(),
          speech_ratio: float(),
          peak_dbfs: float(),
          rms_dbfs: float(),
          snr_db: float(),
          clipped_pct: float(),
          sample_rate: pos_integer(),
          notes: [note()]
        }

  @doc """
  Analyse a reference WAV on disk.

  Returns `{:error, :empty}` for a file with no audio rather than dividing by
  zero into a confident-looking grade.
  """
  @spec analyse(String.t()) :: {:ok, t()} | {:error, term()}
  def analyse(path) when is_binary(path) do
    case SoundStudio.read(path) do
      {:ok, clip} -> analyse_clip(clip)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Analyse an already-parsed clip."
  @spec analyse_clip(SoundStudio.t()) :: {:ok, t()} | {:error, term()}
  def analyse_clip(%SoundStudio{bits: 16} = clip) do
    samples = mono_samples(clip.data, clip.channels)

    case length(samples) do
      0 -> {:error, :empty}
      n -> {:ok, measure(samples, n, clip.sample_rate)}
    end
  end

  def analyse_clip(%SoundStudio{}), do: {:error, :unsupported_bit_depth}

  @doc """
  A one-line verdict for a surface that has room for a sentence and not a table.
  """
  @spec headline(t()) :: String.t()
  def headline(%__MODULE__{grade: :good}), do: "Good recording"
  def headline(%__MODULE__{grade: :fair}), do: "Usable recording"
  def headline(%__MODULE__{grade: :poor}), do: "Poor recording"

  # ---------------------------------------------------------------------------

  defp measure(samples, count, rate) do
    duration_s = count / rate
    peak = samples |> Enum.reduce(0, &max(abs(&1), &2)) |> then(&(&1 / 32_768))
    rms = rms_of(samples, count)
    clipped = Enum.count(samples, &(abs(&1) >= 32_767)) / count * 100

    frames = frame_rms(samples, max(div(rate * @frame_ms, 1000), 1))
    {speech, _noise} = split_speech_and_noise(frames)

    speech_ratio = if frames == [], do: 0.0, else: length(speech) / length(frames)
    snr = snr_db(frames)

    struct = %__MODULE__{
      duration_s: duration_s,
      speech_ratio: speech_ratio,
      peak_dbfs: dbfs(peak),
      rms_dbfs: dbfs(rms),
      snr_db: snr,
      clipped_pct: clipped,
      sample_rate: rate,
      grade: :good
    }

    notes = collect_notes(struct)
    %{struct | notes: notes, grade: grade_from(notes)}
  end

  # Mixing to mono by averaging rather than taking the left channel: a take
  # recorded on a stereo interface with the mic on the right would otherwise
  # grade as silence.
  defp mono_samples(data, 1), do: for(<<s::little-signed-16 <- data>>, do: s)

  defp mono_samples(data, 2) do
    for <<l::little-signed-16, r::little-signed-16 <- data>>, do: div(l + r, 2)
  end

  defp mono_samples(data, _channels), do: mono_samples(data, 1)

  defp rms_of([], _count), do: 0.0

  defp rms_of(samples, count) do
    sum = Enum.reduce(samples, 0, fn s, acc -> acc + s * s end)
    :math.sqrt(sum / count) / 32_768
  end

  defp frame_rms(samples, frame_len) do
    samples
    |> Enum.chunk_every(frame_len, frame_len, :discard)
    |> Enum.map(&rms_of(&1, frame_len))
  end

  # The noise floor is the 10th percentile frame rather than the minimum: one
  # digital-silence frame at the head of a take would otherwise define the floor
  # as zero and make every SNR infinite.
  defp split_speech_and_noise([]), do: {[], []}

  defp split_speech_and_noise(frames) do
    sorted = Enum.sort(frames)
    floor_rms = Enum.at(sorted, div(length(sorted) * 10, 100)) || 0.0
    loudest = List.last(sorted) || 0.0
    absolute = :math.pow(10.0, @absolute_speech_floor_dbfs / 20.0)

    # Three times the floor is the useful threshold for a recording that HAS a
    # floor — speech in a room. It is nonsense for a recording of uniform level,
    # where the floor and the peak are the same number and three times either of
    # them is above everything: a steady tone would grade as 0% speech. So the
    # floor-relative threshold is capped at a fraction of the loudest frame,
    # which is the same rule read from the other end.
    threshold = max(absolute, min(floor_rms * 3, loudest * 0.15))

    Enum.split_with(frames, &(&1 > threshold))
  end

  # Separation is measured as loud-decile against quiet-decile, NOT as the two
  # sides of the speech/silence split above.
  #
  # The split is a decision, and at the noise levels worth warning about it is
  # exactly the decision that stops being reliable: when the room is only a few
  # dB under the voice, every frame lands on the speech side and the split
  # reports a clean recording precisely when it is the dirtiest. Percentiles
  # make no such decision.
  #
  # A clip whose quiet decile is not meaningfully quieter than its loud one has
  # no pauses to measure a room in. That is not a noisy recording, it is an
  # unmeasurable one, and it reports as fine rather than as an alarming 0 dB.
  @unmeasurable_snr_db 60.0

  defp snr_db([]), do: @unmeasurable_snr_db

  defp snr_db(frames) do
    sorted = Enum.sort(frames)
    quiet = percentile(sorted, 10)
    loud = percentile(sorted, 90)

    cond do
      quiet <= 0.0 -> @unmeasurable_snr_db
      loud / quiet < 2.0 -> @unmeasurable_snr_db
      true -> min(20 * :math.log10(loud / quiet), @unmeasurable_snr_db)
    end
  end

  defp percentile(sorted, p) do
    index = min(div(length(sorted) * p, 100), length(sorted) - 1)
    Enum.at(sorted, max(index, 0)) || 0.0
  end

  defp dbfs(+0.0), do: -120.0
  defp dbfs(amplitude) when amplitude <= 0.0, do: -120.0
  defp dbfs(amplitude), do: 20 * :math.log10(amplitude)

  # ---------------------------------------------------------------------------
  # The notes. Order matters: this is the order they are shown, worst first.
  # ---------------------------------------------------------------------------

  defp collect_notes(m) do
    [
      clipping_note(m),
      level_note(m),
      noise_note(m),
      length_note(m),
      silence_note(m)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn %{severity: s} -> if s == :bad, do: 0, else: 1 end)
  end

  defp clipping_note(%{clipped_pct: pct}) when pct > 0.05 do
    %{
      severity: :bad,
      text: "#{fmt(pct)}% of the recording is clipped",
      fix: "Lower the input level and record it again — clipped peaks are waveform that is gone."
    }
  end

  defp clipping_note(_), do: nil

  defp level_note(%{rms_dbfs: rms, peak_dbfs: peak}) when rms < -32.0 do
    %{
      severity: severity_for(rms < -38.0),
      text: "Quiet recording — #{fmt(rms)} dB average, peaking at #{fmt(peak)} dB",
      fix: "Move closer to the microphone or raise its input gain, and record it again."
    }
  end

  defp level_note(_), do: nil

  defp noise_note(%{snr_db: snr}) when snr < 12.0 do
    %{
      severity: severity_for(snr < 8.0),
      text: "The room is loud next to the voice — #{fmt(snr)} dB of separation",
      fix: "Record somewhere quieter, or closer to the microphone so the voice wins."
    }
  end

  defp noise_note(_), do: nil

  defp length_note(%{duration_s: d}) when d > 12.0 do
    %{
      severity: :warn,
      text: "#{fmt(d)} seconds long, and its length is paid on every render",
      fix: "Trim it to about six seconds of your clearest speech — renders get faster."
    }
  end

  defp length_note(%{duration_s: d}) when d < 3.0 do
    %{
      severity: :bad,
      text: "Only #{fmt(d)} seconds long",
      fix: "Record four to ten seconds — a syllable is not enough voice to clone."
    }
  end

  defp length_note(_), do: nil

  defp silence_note(%{speech_ratio: ratio}) when ratio < 0.6 do
    %{
      severity: severity_for(ratio < 0.4),
      text: "Only #{fmt(ratio * 100)}% of it is speech",
      fix: "Trim the pauses at each end — silence costs render time and teaches nothing."
    }
  end

  defp silence_note(_), do: nil

  defp severity_for(true), do: :bad
  defp severity_for(false), do: :warn

  defp grade_from([]), do: :good

  defp grade_from(notes) do
    if Enum.any?(notes, &(&1.severity == :bad)), do: :poor, else: :fair
  end

  defp fmt(number), do: :erlang.float_to_binary(number * 1.0, decimals: 1)
end
