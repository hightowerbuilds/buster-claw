defmodule BusterClaw.Notifications.Cutup.VadTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.Cutup.Vad
  alias BusterClaw.Notifications.SoundStudio

  @rate 22_050

  # A frame is 25 ms and the hop is 10 ms, so a boundary that lands within
  # ~30 ms of the truth is exact as far as this detector can be. Every offset
  # assertion below uses that tolerance rather than a tighter invented one.
  @frame_slop 30.0

  # ---------------------------------------------------------------------------
  # Fixtures — synthetic PCM with known contents
  #
  # Three generators, one per acoustic case the detector claims to handle:
  # digital silence, a periodic tone (voiced: loud, low ZCR), and an alternating
  # +/- sequence (the most unvoiced signal there is: ZCR of exactly 1.0, and any
  # amplitude you like).
  # ---------------------------------------------------------------------------

  defp n(ms), do: round(ms * @rate / 1000)

  defp silence(ms), do: List.duplicate(0, n(ms))

  defp tone(ms, amp, freq \\ 300.0) do
    for i <- 0..(n(ms) - 1)//1 do
      round(amp * 32_767 * :math.sin(2 * :math.pi() * freq * i / @rate))
    end
  end

  # Nyquist-rate noise: every sample flips sign, so ZCR is 1.0 no matter how
  # quiet it is. This is the fricative/room-tone shape in its purest form.
  defp alt(ms, amp) do
    level = round(amp * 32_767)
    for i <- 0..(n(ms) - 1)//1, do: if(rem(i, 2) == 0, do: level, else: -level)
  end

  defp pcm(samples) do
    for s <- samples, into: <<>>, do: <<max(-32_768, min(32_767, s))::little-signed-16>>
  end

  defp clip(samples), do: %SoundStudio{data: pcm(samples)}

  # ---------------------------------------------------------------------------
  # The floor
  # ---------------------------------------------------------------------------

  describe "spans/2 on silence" do
    test "digital silence has no spans at all" do
      c = clip(silence(1000))

      assert Vad.spans(c) == []

      profile = Vad.energy_profile(c)
      assert profile.frame_count > 0
      assert Enum.all?(profile.frames, &(&1.rms == 0.0))
      assert Enum.all?(profile.frames, &(&1.zcr == 0.0))

      # The clamp is what makes this work: the measured floor is literally zero,
      # and no multiple of zero is a usable gate.
      assert profile.thresholds.noise_floor == 0.0
      assert profile.thresholds.enter > 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # Boundaries
  # ---------------------------------------------------------------------------

  describe "spans/2 boundaries" do
    test "one tone burst in silence is exactly one span, at the right offsets" do
      c = clip(silence(500) ++ tone(500, 0.6) ++ silence(500))

      assert [span] = Vad.spans(c)
      assert_in_delta span.start_ms, 500.0, @frame_slop
      assert_in_delta span.end_ms, 1000.0, @frame_slop
      assert span.frames > 1
    end

    test "the reported edges lean outward, which is the safe direction to cut" do
      c = clip(silence(500) ++ tone(500, 0.6) ++ silence(500))

      assert [span] = Vad.spans(c)
      assert span.start_ms <= 500.0
      assert span.end_ms >= 1000.0
    end

    test "three well-separated bursts are three spans" do
      c =
        clip(
          silence(300) ++
            tone(200, 0.6) ++
            silence(300) ++ tone(200, 0.6) ++ silence(300) ++ tone(200, 0.6) ++ silence(300)
        )

      spans = Vad.spans(c)
      assert length(spans) == 3

      [a, b, d] = spans
      assert_in_delta a.start_ms, 300.0, @frame_slop
      assert_in_delta b.start_ms, 800.0, @frame_slop
      assert_in_delta d.start_ms, 1300.0, @frame_slop
    end

    test "min_silence_ms longer than the gaps merges them into one span" do
      c =
        clip(
          silence(300) ++
            tone(200, 0.6) ++
            silence(300) ++ tone(200, 0.6) ++ silence(300) ++ tone(200, 0.6) ++ silence(300)
        )

      assert [merged] = Vad.spans(c, min_silence_ms: 400)
      assert_in_delta merged.start_ms, 300.0, @frame_slop
      assert_in_delta merged.end_ms, 1500.0, @frame_slop
    end
  end

  describe "the stop-consonant rule" do
    # A voiceless stop is a 50-100 ms *silence* inside the word. Without the
    # merge rule, "ticket" is three spans and the cut-up cuts mid-word. These
    # two assertions are the same audio judged with and without the rule.
    setup do
      {:ok,
       clip:
         clip(
           silence(300) ++
             tone(200, 0.6) ++
             silence(60) ++ tone(200, 0.6) ++ silence(60) ++ tone(200, 0.6) ++ silence(300)
         )}
    end

    test "the default does not shatter a word at its stop closures", %{clip: c} do
      assert [span] = Vad.spans(c)
      assert_in_delta span.start_ms, 300.0, @frame_slop
      assert_in_delta span.end_ms, 1020.0, @frame_slop
    end

    test "a tiny min_silence_ms shatters it, which is the failure being fixed", %{clip: c} do
      assert length(Vad.spans(c, min_silence_ms: 10)) == 3
    end
  end

  describe "min_span_ms" do
    test "a blip shorter than the minimum is rejected" do
      c = clip(silence(500) ++ tone(10, 0.6) ++ silence(500))

      assert Vad.spans(c) == []
    end

    test "the same blip is kept when the minimum allows it" do
      c = clip(silence(500) ++ tone(10, 0.6) ++ silence(500))

      assert [span] = Vad.spans(c, min_span_ms: 10)
      assert_in_delta span.start_ms, 500.0, @frame_slop
    end
  end

  # ---------------------------------------------------------------------------
  # The reason ZCR is in this module at all
  # ---------------------------------------------------------------------------

  describe "unvoiced (fricative) activity" do
    # Room tone at -48 dBFS, and a burst only 8 dB above it: too quiet for the
    # +12 dB energy gate, but broadband, which is exactly an `s` next to the
    # vowel that follows it.
    setup do
      {:ok, clip: clip(alt(850, 0.004) ++ alt(300, 0.010) ++ alt(850, 0.004))}
    end

    test "a low-energy, high-ZCR burst is detected", %{clip: c} do
      assert [span] = Vad.spans(c)
      assert_in_delta span.start_ms, 850.0, 40.0
      assert_in_delta span.end_ms, 1150.0, 40.0
    end

    test "an energy-only detector would miss it — the burst is under the energy gate",
         %{clip: c} do
      profile = Vad.energy_profile(c)

      burst =
        Enum.filter(profile.frames, fn f -> f.start_ms >= 900.0 and f.end_ms <= 1100.0 end)

      refute burst == []

      # This is the claim in one line: every frame of the burst sits below the
      # energy threshold, so nothing but the ZCR branch can have found it.
      assert Enum.all?(burst, &(&1.rms < profile.thresholds.enter))
      assert Enum.all?(burst, &(&1.rms >= profile.thresholds.fricative_enter))
      assert Enum.all?(burst, &(&1.zcr > 0.9))
    end

    test "the room tone around it is not activity", %{clip: c} do
      profile = Vad.energy_profile(c)

      quiet = Enum.filter(profile.frames, &(&1.end_ms <= 800.0))
      refute quiet == []
      assert Enum.all?(quiet, &(&1.zcr > 0.9))
      refute Enum.any?(quiet, & &1.hold?)
    end
  end

  # ---------------------------------------------------------------------------
  # Adaptive thresholding
  # ---------------------------------------------------------------------------

  describe "adaptive thresholds" do
    # Two recordings of the same thing 30 dB apart — a handset held at the mouth
    # and one on a table — each with its own proportional noise floor. A fixed
    # absolute threshold cannot serve both; a floor-relative one must.
    defp handset(amp) do
      clip(alt(500, amp / 60) ++ tone(500, amp) ++ alt(500, amp / 60))
    end

    test "the same burst at very different amplitudes yields the same boundaries" do
      loud = Vad.spans(handset(0.6))
      quiet = Vad.spans(handset(0.02))

      assert [_one] = loud
      assert loud == quiet
      assert_in_delta hd(loud).start_ms, 500.0, @frame_slop
      assert_in_delta hd(loud).end_ms, 1000.0, @frame_slop
    end

    test "and it does so by computing genuinely different thresholds" do
      loud = Vad.energy_profile(handset(0.6)).thresholds
      quiet = Vad.energy_profile(handset(0.02)).thresholds

      assert loud.mode == :auto
      assert loud.enter > 10 * quiet.enter
      assert loud.noise_floor > 10 * quiet.noise_floor
    end

    test "an explicit threshold overrides the estimate and is reported as fixed" do
      profile = Vad.energy_profile(handset(0.6), threshold: 0.05)

      assert profile.thresholds.mode == :fixed
      assert profile.thresholds.enter == 0.05
      # The hysteresis ratios survive: leaving is always easier than entering.
      assert profile.thresholds.leave < profile.thresholds.enter
      assert profile.thresholds.fricative_enter < profile.thresholds.enter
      assert profile.thresholds.fricative_leave < profile.thresholds.fricative_enter
    end
  end

  # ---------------------------------------------------------------------------
  # silences/2
  # ---------------------------------------------------------------------------

  describe "silences/2" do
    test "is the complement of spans/2, ends included" do
      c = clip(silence(500) ++ tone(500, 0.6) ++ silence(500))

      assert [span] = Vad.spans(c)
      assert [lead, tail] = Vad.silences(c)

      assert lead.start_ms == 0.0
      assert lead.end_ms == span.start_ms
      assert tail.start_ms == span.end_ms
      assert_in_delta tail.end_ms, SoundStudio.duration_ms(c), 1.0
      assert lead.frames > 0 and tail.frames > 0
    end

    test "a clip that is all silence is one long silence" do
      assert [only] = Vad.silences(clip(silence(800)))
      assert only.start_ms == 0.0
      assert_in_delta only.end_ms, 800.0, 1.0
    end
  end

  # ---------------------------------------------------------------------------
  # trim/2
  # ---------------------------------------------------------------------------

  describe "trim/2" do
    test "removes leading and trailing silence and preserves the middle exactly" do
      body = tone(300, 0.5)
      c = clip(silence(400) ++ body ++ silence(400))

      trimmed = Vad.trim(c, pad_ms: 0)

      # Byte-for-byte: the trimmed clip still contains the original burst as a
      # contiguous run. A trim that resampled, faded or shifted would fail here.
      assert :binary.match(trimmed.data, pcm(body)) != :nomatch

      assert byte_size(trimmed.data) < byte_size(c.data)

      # And it kept almost nothing else: under two frames of slop in total.
      extra = div(byte_size(trimmed.data) - byte_size(pcm(body)), 2)
      assert extra >= 0
      assert extra <= n(60)
    end

    test "pad_ms keeps a margin on each side" do
      c = clip(silence(400) ++ tone(300, 0.5) ++ silence(400))

      tight = Vad.trim(c, pad_ms: 0)
      padded = Vad.trim(c, pad_ms: 50)

      assert byte_size(padded.data) > byte_size(tight.data)
      assert byte_size(padded.data) <= byte_size(c.data)
    end

    test "a clip with no detected activity is returned unchanged, not emptied" do
      c = clip(silence(600))

      assert Vad.trim(c) == c
    end

    test "the clip's format is carried through untouched" do
      c = clip(silence(400) ++ tone(300, 0.5) ++ silence(400))
      trimmed = Vad.trim(c)

      assert trimmed.sample_rate == c.sample_rate
      assert trimmed.channels == c.channels
      assert trimmed.bits == c.bits
    end
  end

  # ---------------------------------------------------------------------------
  # energy_profile/2
  # ---------------------------------------------------------------------------

  describe "energy_profile/2" do
    test "frame i starts at exactly i * hop_ms, with no accumulated drift" do
      profile = Vad.energy_profile(clip(silence(1000)))

      assert profile.hop_ms == 10.0
      assert profile.frame_ms == 25.0

      Enum.each(profile.frames, fn f ->
        assert f.start_ms == f.index * 10.0
        assert f.end_ms == f.index * 10.0 + 25.0
      end)

      # 22050 samples, 551-sample frames stepping 220.5: the last frame that
      # fits starts at index 97.
      assert profile.frame_count == 98
      assert List.last(profile.frames).start_ms == 970.0
    end

    test "a tone reads as high energy and low ZCR" do
      profile = Vad.energy_profile(clip(tone(500, 0.6, 300.0)))
      middle = Enum.at(profile.frames, 20)

      assert_in_delta middle.rms, 0.6 * 0.7071, 0.02
      # 2 * 300 Hz / 22050 Hz.
      assert_in_delta middle.zcr, 0.027, 0.01
    end

    test "Nyquist-rate noise reads as low energy and maximal ZCR" do
      profile = Vad.energy_profile(clip(alt(500, 0.01)))
      middle = Enum.at(profile.frames, 20)

      assert_in_delta middle.rms, 0.01, 0.001
      assert middle.zcr > 0.99
    end
  end

  # ---------------------------------------------------------------------------
  # Degenerate inputs — none of these may raise
  # ---------------------------------------------------------------------------

  describe "degenerate clips" do
    test "an empty clip" do
      c = %SoundStudio{data: <<>>}

      assert Vad.spans(c) == []
      assert Vad.silences(c) == []
      assert Vad.trim(c) == c
      assert Vad.energy_profile(c).frame_count == 0
    end

    test "a clip shorter than a single frame" do
      c = clip(tone(10, 0.6))

      assert Vad.energy_profile(c).frame_count == 0
      assert Vad.spans(c) == []
      assert Vad.trim(c) == c
    end

    test "an all-DC clip is not activity — the offset is removed, not measured" do
      c = clip(List.duplicate(8_000, n(500)))

      profile = Vad.energy_profile(c)
      assert profile.frame_count > 0
      assert Enum.all?(profile.frames, &(&1.rms == 0.0))
      assert Vad.spans(c) == []
      assert Vad.trim(c) == c
    end

    test "a DC offset under a real burst does not hide it" do
      offset = fn samples -> Enum.map(samples, &(&1 + 6_000)) end
      c = clip(offset.(silence(400) ++ tone(300, 0.5) ++ silence(400)))

      assert [span] = Vad.spans(c)
      assert_in_delta span.start_ms, 400.0, @frame_slop
      assert_in_delta span.end_ms, 700.0, @frame_slop
    end

    test "a clip that is not the studio's internal format is not analysed" do
      c = %SoundStudio{sample_rate: 44_100, channels: 2, bits: 16, data: pcm(tone(500, 0.6))}

      assert Vad.spans(c) == []
      assert Vad.energy_profile(c).frame_count == 0
      assert Vad.trim(c) == c
    end

    test "nonsense options fall back to the defaults rather than raising" do
      c = clip(silence(500) ++ tone(500, 0.6) ++ silence(500))

      assert Vad.spans(c, min_span_ms: -50, min_silence_ms: :nope, threshold: :auto) ==
               Vad.spans(c)
    end
  end
end
