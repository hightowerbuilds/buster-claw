defmodule BusterClaw.Notifications.Cutup.SignalTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.Cutup.Signal
  alias BusterClaw.Notifications.Cutup.Signal.Tables
  alias BusterClaw.Notifications.SoundStudio

  @rate 22_050

  # 25 ms at 22.05 kHz. Written out rather than derived, because a test that
  # recomputes the number it is checking cannot catch the number changing.
  @frame_len 551

  # Float tolerance for an FFT of this size. The transform is ~10 stages of
  # multiply-add on doubles, so error accumulates at roughly sqrt(n) * eps.
  @eps 1.0e-9

  # A clip in the studio's internal format from a list of int16 samples.
  defp clip(samples) do
    data = for s <- samples, into: <<>>, do: <<s::little-signed-16>>
    %SoundStudio{sample_rate: @rate, channels: 1, bits: 16, data: data}
  end

  defp silence(n), do: clip(List.duplicate(0, n))

  defp cosine(n, bin, amplitude \\ 1.0) do
    for i <- 0..(n - 1), do: amplitude * :math.cos(2.0 * :math.pi() * bin * i / n)
  end

  defp energy(values), do: Enum.reduce(values, 0.0, fn v, acc -> acc + v * v end)

  # Parseval for the half-spectrum this module returns: the interior bins each
  # stand for a conjugate pair, so they count twice; DC and Nyquist do not.
  defp spectral_energy(spectrum) do
    n = 2 * (length(spectrum) - 1)
    [dc | rest] = spectrum
    {interior, [nyquist]} = Enum.split(rest, length(rest) - 1)

    (dc * dc + nyquist * nyquist + 2 * energy(interior)) / n
  end

  # An independent, deliberately naive O(n^2) DFT. Slow, obviously correct, and
  # the only reference here that is not itself a special case.
  defp naive_dft_magnitudes(x) do
    n = length(x)
    indexed = Enum.with_index(x)

    for k <- 0..div(n, 2) do
      {re, im} =
        Enum.reduce(indexed, {0.0, 0.0}, fn {v, i}, {a, b} ->
          angle = -2.0 * :math.pi() * k * i / n
          {a + v * :math.cos(angle), b + v * :math.sin(angle)}
        end)

      :math.sqrt(re * re + im * im)
    end
  end

  defp assert_all_close(actual, expected, delta \\ @eps) do
    assert length(actual) == length(expected)

    Enum.zip(actual, expected)
    |> Enum.with_index()
    |> Enum.each(fn {{a, e}, i} ->
      assert_in_delta a, e, delta, "bin #{i}: got #{a}, expected #{e}"
    end)
  end

  describe "spectrum/1 — the values are MAGNITUDES, pinned" do
    test "a unit-amplitude sine at a bin centre peaks at n/2, not (n/2)^2" do
      # The convention that has no failure mode if it drifts: `Mfcc` squares
      # these itself. Returning power instead of magnitude would shift every
      # log-domain feature by a constant, break nothing, fail no test on either
      # side alone, and quietly stop a stored template from matching a freshly
      # analysed recording. So it is asserted here against the analytic value.
      n = 1024
      bin = 64
      spectrum = Signal.spectrum(cosine(n, bin))

      assert_in_delta Enum.at(spectrum, bin), n / 2, 1.0e-6

      # And explicitly NOT the power, which is what a `re*re + im*im` slip gives.
      refute_in_delta Enum.at(spectrum, bin), n / 2 * (n / 2), 1.0
    end

    test "amplitude scales the magnitude linearly, not quadratically" do
      n = 256
      quiet = Signal.spectrum(cosine(n, 8, 0.25))
      loud = Signal.spectrum(cosine(n, 8, 1.0))

      # 4x the amplitude is 4x the magnitude. Under a power convention it would
      # be 16x, which is the whole point of pinning it.
      assert_in_delta Enum.at(loud, 8) / Enum.at(quiet, 8), 4.0, 1.0e-9
    end

    test "every magnitude is a non-negative float" do
      spectrum = Signal.spectrum(cosine(64, 5, 0.7))

      assert Enum.all?(spectrum, &(is_float(&1) and &1 >= 0.0))
    end
  end

  describe "spectrum/1 — analytically known signals" do
    test "DC puts all its energy in bin 0" do
      spectrum = Signal.spectrum(List.duplicate(1.0, 8))

      assert_all_close(spectrum, [8.0, 0.0, 0.0, 0.0, 0.0])
    end

    test "DC at the working FFT size" do
      spectrum = Signal.spectrum(List.duplicate(1.0, 1024))
      [dc | rest] = spectrum

      assert_in_delta dc, 1024.0, 1.0e-9
      assert length(rest) == 512
      assert Enum.all?(rest, &(abs(&1) < 1.0e-9))
    end

    test "a sine at exactly a bin centre is a single spike" do
      n = 32
      x = for i <- 0..(n - 1), do: :math.sin(2.0 * :math.pi() * 4 * i / n)
      spectrum = Signal.spectrum(x)

      assert_in_delta Enum.at(spectrum, 4), 16.0, @eps

      spectrum
      |> Enum.with_index()
      |> Enum.each(fn {m, i} -> if i != 4, do: assert(abs(m) < @eps, "bin #{i} = #{m}") end)
    end

    test "two sines at two bin centres give exactly two spikes with the right ratio" do
      n = 32
      a = 1.0
      b = 0.25
      x = Enum.zip_with(cosine(n, 3, a), cosine(n, 11, b), &+/2)
      spectrum = Signal.spectrum(x)

      assert_in_delta Enum.at(spectrum, 3), a * n / 2, @eps
      assert_in_delta Enum.at(spectrum, 11), b * n / 2, @eps
      assert_in_delta Enum.at(spectrum, 3) / Enum.at(spectrum, 11), a / b, 1.0e-9

      spectrum
      |> Enum.with_index()
      |> Enum.each(fn {m, i} ->
        if i not in [3, 11], do: assert(abs(m) < @eps, "bin #{i} = #{m}")
      end)
    end

    test "an impulse has a flat magnitude spectrum" do
      x = [1.0 | List.duplicate(0.0, 15)]

      assert_all_close(Signal.spectrum(x), List.duplicate(1.0, 9))
    end

    test "an alternating signal is pure Nyquist" do
      n = 32
      x = for i <- 0..(n - 1), do: if(rem(i, 2) == 0, do: 1.0, else: -1.0)
      spectrum = Signal.spectrum(x)

      assert_in_delta List.last(spectrum), 32.0, @eps
      assert Enum.all?(Enum.drop(spectrum, -1), &(abs(&1) < @eps))
    end

    test "Parseval's theorem holds — the scaling test the spike tests cannot fail" do
      # Deliberately NOT at bin centres: leakage spreads energy across every bin,
      # so this exercises the whole spectrum rather than one clean spike.
      n = 64
      x = for i <- 0..(n - 1), do: :math.sin(0.3 * i) + 0.5 * :math.cos(1.7 * i) - 0.2 * i / n

      assert_in_delta spectral_energy(Signal.spectrum(x)), energy(x), 1.0e-9
    end

    test "Parseval holds at the working FFT size, on a real windowed frame" do
      samples =
        for i <- 0..(@rate - 1), do: round(8000 * :math.sin(2.0 * :math.pi() * 311 * i / @rate))

      [frame | _] = Signal.frames(clip(samples))

      assert_in_delta spectral_energy(Signal.spectrum(frame)), energy(frame), 1.0e-9
    end

    test "matches a naive DFT bin for bin on a signal with no special structure" do
      n = 64
      x = for i <- 0..(n - 1), do: 3.0 * :math.sin(1.1 * i) + :math.cos(0.4 * i) - 0.5 * rem(i, 7)

      assert_all_close(Signal.spectrum(x), naive_dft_magnitudes(x), 1.0e-10)
    end

    test "returns n/2 + 1 bins, DC through Nyquist inclusive" do
      for n <- [2, 8, 64, 512, 1024] do
        assert length(Signal.spectrum(List.duplicate(1.0, n))) == div(n, 2) + 1
      end
    end
  end

  describe "spectrum/1 — refusals and padding" do
    test "a non-power-of-two frame is zero-padded, never truncated" do
      # A 6-sample impulse. Truncating to 4 would still look like a flat
      # spectrum, so the length is what proves nothing was dropped.
      x = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0]
      spectrum = Signal.spectrum(x)

      assert length(spectrum) == 5
      assert_all_close(spectrum, List.duplicate(1.0, 5))
    end

    test "padding interpolates rather than distorts: energy is preserved" do
      x = [1.0, -2.0, 0.5, 3.0, -1.5, 0.25, 2.0]

      assert length(Signal.spectrum(x)) == 5
      assert_in_delta spectral_energy(Signal.spectrum(x)), energy(x), 1.0e-9
    end

    test "a padded frame agrees with the same frame padded by hand" do
      x = [1.0, -2.0, 0.5, 3.0, -1.5, 0.25, 2.0]
      by_hand = x ++ [0.0]

      assert_all_close(Signal.spectrum(x), Signal.spectrum(by_hand))
    end

    test "an empty frame is refused by name" do
      assert_raise ArgumentError, ~r/non-empty frame/, fn -> Signal.spectrum([]) end
    end
  end

  describe "bit-reversal permutation" do
    test "is its own inverse" do
      for n <- [2, 8, 32, 1024] do
        table = Tables.bit_reversal(n)

        Enum.each(0..(n - 1), fn i ->
          assert elem(table, elem(table, i)) == i, "n=#{n}, i=#{i}"
        end)
      end
    end

    test "is a permutation of 0..n-1 — no index dropped or duplicated" do
      for n <- [2, 8, 32, 1024] do
        assert table_to_sorted_list(n) == Enum.to_list(0..(n - 1))
      end
    end

    test "reverses the bits it says it does" do
      # n = 8 is three bits: 1 (001) <-> 4 (100), 3 (011) <-> 6 (110).
      assert Tuple.to_list(Tables.bit_reversal(8)) == [0, 4, 2, 6, 1, 5, 3, 7]
    end

    defp table_to_sorted_list(n) do
      n |> Tables.bit_reversal() |> Tuple.to_list() |> Enum.sort()
    end
  end

  describe "the analysis frame is fixed" do
    test "25 ms frames at a 10 ms hop, matching Cutup.Types" do
      assert Signal.frame_ms() == 25.0
      assert Signal.hop_ms() == 10.0
    end

    test "the default FFT size is large enough to hold a frame without truncating" do
      assert Signal.default_fft_size() >= round(Signal.frame_ms() * @rate / 1000)
    end
  end

  describe "frame_index_to_ms/1" do
    test "frame i starts at i * hop_ms, exactly" do
      assert Signal.frame_index_to_ms(0) == 0.0
      assert Signal.frame_index_to_ms(1) == 10.0
      assert Signal.frame_index_to_ms(100) == 1000.0
      assert Signal.frame_index_to_ms(29_500) == 295_000.0
    end

    test "round-trips through the hop: ms / hop_ms == the index it came from" do
      for i <- [0, 1, 7, 250, 29_499] do
        assert Signal.frame_index_to_ms(i) / Signal.hop_ms() == i * 1.0
      end
    end

    test "consecutive frames are exactly one hop apart, with no accumulated drift" do
      deltas =
        0..999
        |> Enum.map(&Signal.frame_index_to_ms/1)
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> b - a end)

      assert Enum.all?(deltas, &(abs(&1 - 10.0) < 1.0e-9))
    end

    test "never drifts more than half a sample from the offset framing actually cuts at" do
      # The bug this guards: rounding 220.5 samples to a fixed integer stride and
      # accumulating it. Over the 295 s corpus that is 0.67 s of drift, which is
      # several words. Recomputing from the index keeps the error bounded.
      hop_samples = Signal.hop_ms() * @rate / 1000

      worst =
        Enum.reduce(0..29_500, 0.0, fn i, worst ->
          cut_ms = round(i * hop_samples) * 1000 / @rate
          max(worst, abs(cut_ms - Signal.frame_index_to_ms(i)))
        end)

      # Half a sample, in ms — and the bound is tight: `round/1` reaches exactly
      # half a sample on the frames where `i * 220.5` lands on a .5, so the
      # tolerance is for float representation, not for slop in the framing.
      assert worst <= 500 / @rate + 1.0e-9
    end

    test "a click lands in the frame frame_index_to_ms/1 points at" do
      # The end-to-end round trip: audio -> frames -> index -> back to a time.
      click_ms = 1500
      click_at = round(click_ms * @rate / 1000)

      samples =
        for i <- 0..(3 * @rate - 1) do
          if i >= click_at and i < click_at + 100, do: 20_000, else: 0
        end

      {_energy, index} =
        samples
        |> clip()
        |> Signal.frames()
        |> Enum.map(&energy/1)
        |> Enum.with_index()
        |> Enum.max()

      found = Signal.frame_index_to_ms(index)

      # The loudest frame is one whose 25 ms window contains the click, so its
      # start sits within one frame length below it.
      assert found <= click_ms
      assert click_ms - found < Signal.frame_ms()
    end
  end

  describe "frames/2 — geometry" do
    test "one second at 22.05 kHz yields 98 frames" do
      # 22050 samples, 551-sample frames, 220.5-sample hop. Frame i starts at
      # round(i * 220.5); the last one that fits whole is i = 97.
      assert length(Signal.frames(silence(@rate))) == 98
      assert round(97 * 220.5) + @frame_len <= @rate
      assert round(98 * 220.5) + @frame_len > @rate
    end

    test "every frame is exactly fft_size floats long" do
      frames = Signal.frames(silence(@rate))

      assert Enum.all?(frames, &(length(&1) == Signal.default_fft_size()))
      assert Enum.all?(frames, &Enum.all?(&1, fn v -> is_float(v) end))
    end

    test "an explicit fft_size changes the padded length but not the frame count" do
      frames = Signal.frames(silence(@rate), fft_size: 2048)

      assert length(frames) == 98
      assert Enum.all?(frames, &(length(&1) == 2048))
    end

    test "a clip shorter than one frame yields zero frames, not a padded one" do
      assert Signal.frames(silence(@frame_len - 1)) == []
      assert Signal.frames(silence(1)) == []
      assert Signal.frames(silence(0)) == []
    end

    test "a clip of exactly one frame yields exactly one frame" do
      assert length(Signal.frames(silence(@frame_len))) == 1
    end

    test "the trailing partial frame is dropped" do
      # One sample short of a second frame fitting.
      assert length(Signal.frames(silence(@frame_len + 220))) == 1
      assert length(Signal.frames(silence(@frame_len + 221))) == 2
    end

    test "the padding is zeros beyond the real samples" do
      [frame] = Signal.frames(clip(List.duplicate(12_000, @frame_len)))

      assert Enum.drop(frame, @frame_len) == List.duplicate(0.0, 1024 - @frame_len)
      refute Enum.at(frame, 0) == 0.0
    end
  end

  describe "frames/2 — the windowed, pre-emphasised content" do
    test "the Hamming window endpoints are 0.08" do
      window = Tables.hamming(@frame_len)

      assert_in_delta List.first(window), 0.08, 1.0e-12
      assert_in_delta List.last(window), 0.08, 1.0e-12
      assert length(window) == @frame_len
    end

    test "the window peaks at 1.0 in the middle and is symmetric" do
      window = Tables.hamming(101)

      assert_in_delta Enum.at(window, 50), 1.0, 1.0e-12
      assert_all_close(window, Enum.reverse(window), 1.0e-12)
    end

    test "the first sample of the first frame is x[0] * 0.08 — window edge and a zero filter history" do
      # Pre-emphasis has no earlier sample at the very start of the clip, so
      # y[0] = x[0], and the window's first tap is 0.08.
      [frame] = Signal.frames(clip(List.duplicate(16_384, @frame_len)))

      assert_in_delta Enum.at(frame, 0), 16_384 / 32_768 * 0.08, 1.0e-12
    end

    test "pre-emphasis removes DC: a constant clip is scaled by (1 - 0.97)" do
      [frame] = Signal.frames(clip(List.duplicate(16_384, @frame_len)))
      window = Tables.hamming(@frame_len)

      # Every sample past the first: y = x - 0.97x = 0.03x, windowed.
      Enum.each(1..(@frame_len - 1), fn i ->
        expected = 0.5 * (1 - 0.97) * Enum.at(window, i)
        assert_in_delta Enum.at(frame, i), expected, 1.0e-12
      end)
    end

    test "PCM16 is normalised into -1.0..1.0" do
      [frame] =
        Signal.frames(clip([-32_768 | List.duplicate(0, @frame_len - 1)]), pre_emphasis: 0.0)

      window = Tables.hamming(@frame_len)

      assert_in_delta Enum.at(frame, 0), -1.0 * Enum.at(window, 0), 1.0e-12
      assert Enum.all?(frame, &(&1 >= -1.0 and &1 <= 1.0))
    end

    test "pre_emphasis: 0.0 leaves nothing but the window" do
      samples = for i <- 0..(@frame_len - 1), do: rem(i * 137, 4001) - 2000
      [frame] = Signal.frames(clip(samples), pre_emphasis: 0.0)
      window = Tables.hamming(@frame_len)

      expected = Enum.zip_with(samples, window, fn s, w -> s / 32_768 * w end)
      assert_all_close(Enum.take(frame, @frame_len), expected, 1.0e-12)
    end

    test "the filter runs across the frame boundary, so frame 1 is continuous with frame 0" do
      # The bug this catches: restarting the filter at each frame start, which
      # puts a spurious transient in the first sample of every frame — 100 times
      # a second, in every feature vector.
      samples = for i <- 0..(3 * @frame_len), do: rem(i * 977, 8001) - 4000
      [_first, frame] = Enum.take(Signal.frames(clip(samples)), 2)
      window = Tables.hamming(@frame_len)
      start = round(220.5)

      expected =
        for j <- 0..(@frame_len - 1) do
          x = Enum.at(samples, start + j) / 32_768
          prev = Enum.at(samples, start + j - 1) / 32_768
          (x - 0.97 * prev) * Enum.at(window, j)
        end

      assert_all_close(Enum.take(frame, @frame_len), expected, 1.0e-12)
    end
  end

  describe "frames/2 — refusals" do
    test "an fft_size smaller than the frame is refused, not silently truncated" do
      assert_raise ArgumentError, ~r/smaller than the 551-sample analysis frame/, fn ->
        Signal.frames(silence(@rate), fft_size: 512)
      end
    end

    test "a 44.1 kHz clip needs a bigger FFT, and says so" do
      hi = %SoundStudio{
        sample_rate: 44_100,
        channels: 1,
        bits: 16,
        data: <<0::size(44_100 * 16)>>
      }

      assert_raise ArgumentError, ~r/Pass a larger :fft_size \(2048 or more\)/, fn ->
        Signal.frames(hi)
      end

      assert length(Signal.frames(hi, fft_size: 2048)) == 98
    end

    test "a clip that is not mono PCM16 is refused by name" do
      stereo = %SoundStudio{sample_rate: @rate, channels: 2, bits: 16, data: <<0::size(1024)>>}
      eight_bit = %SoundStudio{sample_rate: @rate, channels: 1, bits: 8, data: <<0::size(1024)>>}

      assert_raise ArgumentError, ~r/mono PCM16/, fn -> Signal.frames(stereo) end
      assert_raise ArgumentError, ~r/mono PCM16/, fn -> Signal.frames(eight_bit) end
    end
  end

  describe "frames/2 into spectrum/1" do
    test "a pure tone lands in the bin the sample rate says it should" do
      # 861.33 Hz is bin 40 at 22.05 kHz with a 1024-point FFT
      # (40 * 22050 / 1024), so it sits on a bin centre and does not smear.
      freq = 40 * @rate / 1024

      samples =
        for i <- 0..(@rate - 1),
            do: round(20_000 * :math.sin(2.0 * :math.pi() * freq * i / @rate))

      spectrum =
        clip(samples)
        |> Signal.frames(pre_emphasis: 0.0)
        |> Enum.at(50)
        |> Signal.spectrum()

      {_peak, bin} = spectrum |> Enum.with_index() |> Enum.max()

      assert bin == 40
    end

    test "silence produces a spectrum of zeros" do
      [frame | _] = Signal.frames(silence(@rate))

      assert Enum.all?(Signal.spectrum(frame), &(&1 == 0.0))
    end
  end

  @tag :bench
  test "throughput — the performance budget, measured rather than assumed" do
    seconds = 3
    freq = 220.0

    samples =
      for i <- 0..(seconds * @rate - 1) do
        round(9000 * :math.sin(2.0 * :math.pi() * freq * i / @rate))
      end

    source = clip(samples)
    warm = Signal.frames(source)
    count = length(warm)
    Signal.spectrum(hd(warm))

    {frame_us, _} = :timer.tc(fn -> Signal.frames(source) end)
    {fft_us, _} = :timer.tc(fn -> Enum.each(warm, &Signal.spectrum/1) end)

    total_s = (frame_us + fft_us) / 1_000_000
    fps = count / total_s
    corpus_frames = 29_500

    IO.puts("""

    Cutup.Signal throughput (fft_size #{Signal.default_fft_size()}, #{@rate} Hz)
      frames/2   #{Float.round(count / (frame_us / 1_000_000), 1)} frames/s
      spectrum/1 #{Float.round(count / (fft_us / 1_000_000), 1)} frames/s
      combined   #{Float.round(fps, 1)} frames/s (#{Float.round(seconds / total_s, 1)}x realtime)
      projected  #{Float.round(corpus_frames / fps, 1)} s single-core for the 295 s corpus
    """)

    # A floor, not a target: this asserts the pipeline has not become
    # accidentally quadratic (an `Enum.at` creeping into the butterfly loop
    # would cost ~500x here), and nothing finer. CI machines vary.
    assert fps > 25, "#{Float.round(fps, 1)} frames/s is far below the budget"
  end
end
