defmodule BusterClaw.Notifications.Capture.TakeTest do
  @moduledoc """
  `Capture.Take.decode/2` — what turns the browser's samples into a clip. Its
  caller is `Voice.Reference`, the Vox2B reference recorder.

  `store/3` and its index tests left 09-19 with the cut-up engine
  (`CUTUP_DELETION_ROADMAP`). Nothing here touches the database or the disk any
  more, so this runs async.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.Capture.Take
  alias BusterClaw.Notifications.SoundStudio

  @rate 48_000

  # A short tone at a given amplitude, as the browser would send it: base64
  # Float32 little-endian.
  defp pcm(amplitude, samples \\ 480) do
    0..(samples - 1)
    |> Enum.map(fn i -> amplitude * :math.sin(2 * :math.pi() * 440 * i / @rate) end)
    |> Enum.reduce(<<>>, fn f, acc -> acc <> <<f::little-float-32>> end)
    |> Base.encode64()
  end

  describe "decode" do
    test "float PCM becomes a 16-bit mono clip at the rate the device ran at" do
      assert {:ok, take} = Take.decode(pcm(0.5), @rate)

      assert %SoundStudio{sample_rate: @rate, channels: 1, bits: 16} = take.clip
      assert SoundStudio.sample_count(take.clip) == 480
      assert_in_delta take.duration_ms, 10.0, 0.001
    end

    test "nothing is resampled — the native rate is archived" do
      assert {:ok, %{sample_rate: 44_100, clip: %{sample_rate: 44_100}}} =
               Take.decode(pcm(0.5), 44_100)
    end

    test "peak is measured on the floats, before int16 conversion can clamp it" do
      assert {:ok, %{peak: peak, clipped?: false}} = Take.decode(pcm(0.5), @rate)
      assert_in_delta peak, 0.5, 0.01
    end

    test "a take at full scale is reported as clipped" do
      assert {:ok, %{clipped?: true}} = Take.decode(pcm(1.0), @rate)
    end

    test "beyond full scale is clipped, and the int16 conversion does not wrap" do
      assert {:ok, %{clipped?: true, clip: clip}} = Take.decode(pcm(1.5), @rate)

      # Every sample must land inside the signed 16-bit rails. A naive scale
      # would wrap a +1.5 sample to a large NEGATIVE one, which is the loudest
      # possible click at exactly the loudest moment of a take.
      for <<sample::little-signed-16 <- clip.data>> do
        assert sample >= -32_768 and sample <= 32_767
      end
    end

    test "digital silence is a failure, not a quiet success" do
      assert {:error, :silent_take} = Take.decode(pcm(0.0), @rate)
    end

    test "an empty buffer is refused" do
      assert {:error, :empty_take} = Take.decode(Base.encode64(<<>>), @rate)
    end

    test "a truncated float buffer is refused rather than silently shortened" do
      assert {:error, :invalid_pcm} = Take.decode(Base.encode64(<<0, 0, 0>>), @rate)
    end

    test "refuses a rate the hardware could not have produced" do
      for bad <- [0, 100, 1_000_000, "48000", nil] do
        assert {:error, :invalid_sample_rate} = Take.decode(pcm(0.5), bad)
      end
    end

    test "refuses anything that is not base64" do
      assert {:error, :invalid_pcm} = Take.decode("not base64!!", @rate)
      assert {:error, :invalid_pcm} = Take.decode(:nonsense, @rate)
    end
  end
end
