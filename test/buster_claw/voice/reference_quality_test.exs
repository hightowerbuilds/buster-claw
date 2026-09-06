defmodule BusterClaw.Voice.ReferenceQualityTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Voice.ReferenceQuality

  @rate 16_000

  # A tone rather than real speech, because the grader measures level, silence
  # and noise — none of which need a voice to be present, and all of which need
  # to be exactly controllable to assert on.
  defp tone(seconds, amplitude, opts \\ []) do
    silence_every = Keyword.get(opts, :silence_every, nil)
    noise = Keyword.get(opts, :noise, 0)
    count = round(@rate * seconds)

    data =
      for i <- 0..(count - 1), into: <<>> do
        silent? = silence_every && rem(div(i, div(@rate, 2)), 2) == 1

        value =
          if silent? do
            room(noise, i)
          else
            round(amplitude * :math.sin(2 * :math.pi() * 220 * i / @rate)) + room(noise, i)
          end

        <<clamp(value)::little-signed-16>>
      end

    %SoundStudio{sample_rate: @rate, channels: 1, bits: 16, data: data}
  end

  # Deterministic pseudo-noise: a test that grades noise must not be a test that
  # sometimes grades noise.
  defp room(0, _i), do: 0
  defp room(level, i), do: rem(i * 7919, 2 * level) - level

  defp clamp(v) when v > 32_767, do: 32_767
  defp clamp(v) when v < -32_768, do: -32_768
  defp clamp(v), do: v

  defp grade(clip) do
    {:ok, quality} = ReferenceQuality.analyse_clip(clip)
    quality
  end

  defp note_texts(quality), do: Enum.map(quality.notes, & &1.text)

  describe "a recording with nothing wrong with it" do
    test "grades good and says nothing" do
      quality = grade(tone(6.0, 8_000))

      assert quality.grade == :good
      assert quality.notes == []
      assert_in_delta quality.duration_s, 6.0, 0.01
      assert quality.clipped_pct == 0.0
    end

    test "a steady level is not mistaken for silence" do
      # The bug this pins: with a uniform signal the noise floor and the peak are
      # the same number, so a floor-relative threshold alone puts every frame
      # BELOW it and the clip grades as 0% speech.
      quality = grade(tone(6.0, 8_000))

      assert quality.speech_ratio == 1.0
    end
  end

  describe "level" do
    test "a quiet recording is reported with its own numbers" do
      quality = grade(tone(6.0, 300))

      assert quality.grade in [:fair, :poor]
      assert quality.rms_dbfs < -32.0
      assert Enum.any?(note_texts(quality), &(&1 =~ "Quiet recording"))
    end

    test "clipping is a bad note, not a warning" do
      quality = grade(tone(6.0, 40_000))

      assert quality.grade == :poor
      assert quality.clipped_pct > 0.05
      assert %{severity: :bad} = Enum.find(quality.notes, &(&1.text =~ "clipped"))
    end
  end

  describe "length, which is paid on every render" do
    test "too long is a warning that names the cost" do
      quality = grade(tone(14.0, 8_000))

      assert quality.grade == :fair
      note = Enum.find(quality.notes, &(&1.text =~ "paid on every render"))
      assert note.severity == :warn
      assert note.fix =~ "six seconds"
    end

    test "too short is bad — there is not enough voice to clone" do
      quality = grade(tone(1.5, 8_000))

      assert quality.grade == :poor
      assert %{severity: :bad} = Enum.find(quality.notes, &(&1.text =~ "seconds long"))
    end
  end

  describe "silence and noise" do
    test "a clip that is half pauses reports its speech ratio" do
      quality = grade(tone(8.0, 8_000, silence_every: true))

      assert quality.speech_ratio < 0.6
      assert Enum.any?(note_texts(quality), &(&1 =~ "% of it is speech"))
    end

    test "a loud room next to a quiet voice is separated out" do
      quality = grade(tone(8.0, 900, silence_every: true, noise: 500))

      assert quality.snr_db < 12.0
      assert Enum.any?(note_texts(quality), &(&1 =~ "room is loud"))
    end
  end

  describe "what it refuses to do" do
    test "an empty clip is an error, not a confident grade" do
      clip = %SoundStudio{sample_rate: @rate, channels: 1, bits: 16, data: <<>>}

      assert {:error, :empty} = ReferenceQuality.analyse_clip(clip)
    end

    test "a bit depth it cannot read says so" do
      clip = %SoundStudio{sample_rate: @rate, channels: 1, bits: 24, data: <<0, 0, 0>>}

      assert {:error, :unsupported_bit_depth} = ReferenceQuality.analyse_clip(clip)
    end

    test "a missing file is an error" do
      assert {:error, _} = ReferenceQuality.analyse("/nope/not-here.wav")
    end
  end

  describe "headline" do
    test "names the grade in words a person reads" do
      assert ReferenceQuality.headline(%ReferenceQuality{grade: :good}) == "Good recording"
      assert ReferenceQuality.headline(%ReferenceQuality{grade: :fair}) == "Usable recording"
      assert ReferenceQuality.headline(%ReferenceQuality{grade: :poor}) == "Poor recording"
    end
  end
end
