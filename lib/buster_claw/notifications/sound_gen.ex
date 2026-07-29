defmodule BusterClaw.Notifications.SoundGen do
  @moduledoc """
  Synthesizes the bundled default sound set (SOUND_ROADMAP Phase 0).

  Every default chime is generated here — envelope-shaped sine tones with one
  octave partial for body, PCM16 mono WAV at 22.05 kHz — because sounds we
  synthesize are ours by construction: no licensing provenance to audit, no
  third-party pack whose taste we inherit, and a set that can be regenerated
  byte-identically (`scripts/gen_sounds.exs`) instead of curated. DTMF for the
  dialpad is NOT here — that's client-side WebAudio (Phase 3), no files at all.

  ## Determinism

  Same machine → byte-identical output: the synthesis is pure arithmetic with
  no time, randomness, or environment input. (Cross-machine, libm's `sin` may
  differ in the last ulp, which is why the generated WAVs are committed rather
  than built — the generator is the *recipe*, the repo holds the *dish*.)

  ## The sound language

  One family, so the set sounds designed rather than collected: pure tones with
  a soft 5 ms attack and exponential decay. Meaning is carried by contour —
  rising = something arrived or wants you (confirm, boot), falling = something
  stopped (shift), low = something is stuck (blocked), doubles = messages
  (voicemail, sms, timer), a chord = money (order), and `security`/`alarm` are
  the only two that repeat, because repetition is the audio spelling of "act".
  """

  @sample_rate 22_050
  # Full-scale headroom: summed tones clip past 1.0, and a clipped chime sounds
  # exactly like the cheap synthesis Part V warns about.
  @master 0.82

  # A tone: frequency, onset, length, loudness. `partial` mixes in the octave
  # above at that fraction for body. All times in ms so specs read musically.
  defp tone(f, at, dur, amp, partial \\ 0.25),
    do: %{f: f, at: at, dur: dur, amp: amp, partial: partial}

  # ---------------------------------------------------------------------------
  # The set — one spec per routing key (SOUND_ROADMAP Part II).
  # Pitches: A5 880 · B5 987.8 · C6 1046.5 · D6 1174.7 · E6 1318.5 · G5 784.
  # ---------------------------------------------------------------------------

  # A function, not a module attribute: `tone/5` is a private function, and
  # attributes are evaluated before any function exists. Rebuilt per call, which
  # is nothing — the generator runs when someone edits the set.
  defp specs do
    %{
      # -- kinds (the notification classics; bundled ON means these ring day one)
      "timer" => [tone(1318.5, 0, 110, 0.7), tone(1318.5, 190, 110, 0.7)],
      "alarm" => [
        # Rising triple, twice — the polite alarm; `security` is the impolite one.
        tone(880.0, 0, 170, 0.8),
        tone(1108.7, 180, 170, 0.8),
        tone(1318.5, 360, 220, 0.85),
        tone(880.0, 640, 170, 0.8),
        tone(1108.7, 820, 170, 0.8),
        tone(1318.5, 1000, 260, 0.85)
      ],
      "reminder" => [tone(784.0, 0, 200, 0.6), tone(987.8, 210, 320, 0.6)],

      # -- sources
      "chat" => [tone(1174.7, 0, 320, 0.65)],
      "terminal" => [tone(880.0, 0, 140, 0.6, 0.4)],
      "email" => [tone(784.0, 0, 300, 0.55)],
      "voicemail" => [tone(800.0, 0, 130, 0.7, 0.0), tone(800.0, 220, 130, 0.7, 0.0)],
      "manual" => [tone(1046.5, 0, 260, 0.6)],

      # -- group A: agent attention
      "confirm" => [tone(880.0, 0, 150, 0.75), tone(1174.7, 160, 300, 0.8)],
      "order" => [
        tone(784.0, 0, 380, 0.6),
        tone(1046.5, 0, 380, 0.6),
        tone(1568.0, 0, 300, 0.3, 0.0)
      ],
      "shift" => [tone(1174.7, 0, 190, 0.7), tone(880.0, 200, 300, 0.7)],
      "blocked" => [tone(220.0, 0, 140, 0.85, 0.5), tone(220.0, 200, 180, 0.85, 0.5)],
      "web" => [tone(987.8, 0, 180, 0.6)],

      # -- group B
      "sms" => [tone(1568.0, 0, 80, 0.65, 0.0), tone(1568.0, 130, 80, 0.65, 0.0)],

      # -- group C: the klaxon. Alternating two-tone, the only harsh thing in the
      # set, because it is the only event where startling the operator is the job.
      "security" => [
        tone(950.0, 0, 150, 0.9, 0.0),
        tone(750.0, 150, 150, 0.9, 0.0),
        tone(950.0, 300, 150, 0.9, 0.0),
        tone(750.0, 450, 150, 0.9, 0.0),
        tone(950.0, 600, 150, 0.9, 0.0),
        tone(750.0, 750, 200, 0.9, 0.0)
      ],

      # -- group D
      "boot" => [
        tone(523.25, 0, 260, 0.5),
        tone(659.26, 110, 260, 0.5),
        tone(784.0, 220, 260, 0.5),
        tone(1046.5, 330, 420, 0.6)
      ]
    }
  end

  @doc "The routing keys this generator produces a default for."
  def keys, do: specs() |> Map.keys() |> Enum.sort()

  @doc "Render one key's chime as a complete WAV binary."
  def render(key), do: specs() |> Map.fetch!(key) |> wav()

  @doc """
  Write the whole set as `<key>.wav` into `dir`. Returns the sorted filenames.
  """
  def write_all(dir) do
    File.mkdir_p!(dir)

    for key <- keys() do
      name = key <> ".wav"
      File.write!(Path.join(dir, name), render(key))
      name
    end
  end

  # ---------------------------------------------------------------------------
  # Synthesis
  # ---------------------------------------------------------------------------

  defp wav(tones) do
    total_ms = Enum.map(tones, &(&1.at + &1.dur)) |> Enum.max()
    # A 60 ms silent tail so decays land on zero instead of a truncation click.
    n = ms_to_samples(total_ms + 60)

    data =
      for i <- 0..(n - 1), into: <<>> do
        t_ms = i * 1000.0 / @sample_rate

        sample =
          tones
          |> Enum.map(&tone_sample(&1, t_ms))
          |> Enum.sum()
          |> Kernel.*(@master)
          |> min(1.0)
          |> max(-1.0)

        <<round(sample * 32_767)::little-signed-16>>
      end

    header(data) <> data
  end

  defp tone_sample(%{at: at, dur: dur}, t_ms) when t_ms < at or t_ms >= at + dur, do: 0.0

  defp tone_sample(%{f: f, at: at, dur: dur, amp: amp, partial: partial}, t_ms) do
    local = t_ms - at
    t = t_ms / 1000.0

    # Soft attack (5 ms ramp), exponential decay over the tone, and a hard
    # 8 ms fade-out at the end — the three edges that keep sines from clicking.
    envelope =
      min(local / 5.0, 1.0) *
        :math.exp(-3.5 * local / dur) *
        min((dur - local) / 8.0, 1.0)

    fundamental = :math.sin(2.0 * :math.pi() * f * t)
    octave = :math.sin(2.0 * :math.pi() * f * 2.0 * t)

    amp * envelope * (fundamental + partial * octave) / (1.0 + partial)
  end

  defp header(data) do
    byte_len = byte_size(data)
    block_align = 2
    byte_rate = @sample_rate * block_align

    <<"RIFF", 36 + byte_len::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      @sample_rate::little-32, byte_rate::little-32, block_align::little-16, 16::little-16,
      "data", byte_len::little-32>>
  end

  defp ms_to_samples(ms), do: trunc(ms * @sample_rate / 1000)
end
