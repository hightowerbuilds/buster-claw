defmodule BusterClaw.Notifications.Cutup.MfccTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Notifications.Cutup.Mfcc

  @fft 512
  @rate 22_050
  @bins div(@fft, 2) + 1

  # A spectrum with a single spike, everything else at zero. Enough to prove
  # where a frequency lands without needing the FFT stage to exist.
  defp spike(bin, magnitude \\ 1.0) do
    Enum.map(0..(@bins - 1), fn k -> if k == bin, do: magnitude, else: 0.0 end)
  end

  # Something with energy everywhere, so a log of a floored band is not what the
  # test is measuring. Deterministic, no randomness.
  defp broadband(seed) do
    Enum.map(0..(@bins - 1), fn k -> 0.1 + abs(:math.sin(seed * 0.7 + k * 0.11)) end)
  end

  defp bank, do: Mfcc.new(fft_size: @fft, sample_rate: @rate)

  defp bin_nearest(hz), do: round(hz / (@rate / @fft))

  defp argmax(values) do
    {_value, index} = values |> Enum.with_index() |> Enum.max_by(fn {v, _i} -> v end)
    index
  end

  describe "the mel scale" do
    test "round-trips across the audible range" do
      for hz <- [0.0, 1.0, 50.0, 300.0, 700.0, 1000.0, 3400.0, 4000.0, 8000.0, 11_025.0] do
        assert_in_delta Mfcc.mel_to_hz(Mfcc.hz_to_mel(hz)), hz, 1.0e-6
      end
    end

    test "round-trips the other way too" do
      for mel <- [0.0, 100.0, 1000.0, 2595.0, 3900.0] do
        assert_in_delta Mfcc.hz_to_mel(Mfcc.mel_to_hz(mel)), mel, 1.0e-6
      end
    end

    test "anchors at zero and is strictly increasing" do
      assert Mfcc.hz_to_mel(0.0) == 0.0
      assert Mfcc.mel_to_hz(0.0) == 0.0

      mels = Enum.map(0..110, fn i -> Mfcc.hz_to_mel(i * 100.0) end)
      assert mels == Enum.sort(mels)
      assert Enum.uniq(mels) == mels
    end

    test "compresses the top of the range relative to the bottom" do
      # The whole point of the scale: 0-1 kHz gets more mel room than 10-11 kHz.
      low_span = Mfcc.hz_to_mel(1000.0) - Mfcc.hz_to_mel(0.0)
      high_span = Mfcc.hz_to_mel(11_000.0) - Mfcc.hz_to_mel(10_000.0)
      assert low_span > 3 * high_span
    end
  end

  describe "mel_filterbank/3" do
    test "produces the requested number of filters" do
      assert length(Mfcc.mel_filterbank(26, @fft, @rate)) == 26
      assert length(Mfcc.mel_filterbank(40, 1024, @rate)) == 40
    end

    test "every weight is non-negative and no greater than one" do
      for filter <- Mfcc.mel_filterbank(26, @fft, @rate),
          {_bin, weight} <- filter.weights do
        assert weight > 0.0
        assert weight <= 1.0 + 1.0e-12
      end
    end

    test "every filter is triangular: weights rise to a peak, then fall" do
      for filter <- Mfcc.mel_filterbank(26, @fft, @rate) do
        weights = Enum.map(filter.weights, &elem(&1, 1))
        assert weights != []

        peak = Enum.max(weights)
        {rising, falling} = Enum.split_while(weights, &(&1 < peak))

        assert rising == Enum.sort(rising), "filter #{filter.index} is not monotonic rising"

        assert falling == Enum.sort(falling, :desc),
               "filter #{filter.index} is not monotonic falling"
      end
    end

    test "bins are listed in ascending order and are contiguous" do
      for filter <- Mfcc.mel_filterbank(26, @fft, @rate) do
        bins = Enum.map(filter.weights, &elem(&1, 0))
        assert bins == Enum.sort(bins)
        assert bins == Enum.to_list(List.first(bins)..List.last(bins))
      end
    end

    test "adjacent filters overlap, and non-adjacent ones do not" do
      filters = Mfcc.mel_filterbank(26, @fft, @rate)

      bin_sets =
        Enum.map(filters, fn f -> f.weights |> Enum.map(&elem(&1, 0)) |> MapSet.new() end)

      bin_sets
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] ->
        assert MapSet.size(MapSet.intersection(a, b)) > 0, "adjacent filters share no bin"
      end)

      # Filter i and filter i+2 meet only at a single corner frequency, which is
      # a zero-weight point, so they never share a bin with weight above zero.
      bin_sets
      |> Enum.chunk_every(3, 1, :discard)
      |> Enum.each(fn [a, _b, c] ->
        assert MapSet.size(MapSet.intersection(a, c)) == 0, "filters two apart overlap"
      end)
    end

    test "the bank spans DC to Nyquist without exceeding it" do
      filters = Mfcc.mel_filterbank(26, @fft, @rate)
      first = List.first(filters)
      last = List.last(filters)
      nyquist = @rate / 2

      assert first.low_hz == 0.0
      assert last.high_hz == nyquist
      assert Enum.all?(filters, &(&1.high_hz <= nyquist))
      assert Enum.all?(filters, &(&1.low_hz >= 0.0))
      assert Enum.all?(filters, &(&1.low_hz < &1.center_hz and &1.center_hz < &1.high_hz))
    end

    test "centres are equally spaced on the mel scale" do
      filters = Mfcc.mel_filterbank(26, @fft, @rate)

      steps =
        filters
        |> Enum.map(&Mfcc.hz_to_mel(&1.center_hz))
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> b - a end)

      first = List.first(steps)
      assert Enum.all?(steps, &(abs(&1 - first) < 1.0e-6))
    end

    test "each filter's corners are the neighbours' centres — the bank tiles without holes" do
      filters = Mfcc.mel_filterbank(26, @fft, @rate)

      filters
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] ->
        assert_in_delta a.high_hz, b.center_hz, 1.0e-9
        assert_in_delta b.low_hz, a.center_hz, 1.0e-9
      end)
    end

    test "honours a restricted band" do
      filters = Mfcc.mel_filterbank(26, @fft, @rate, low_hz: 300.0, high_hz: 3400.0)
      assert List.first(filters).low_hz == 300.0
      assert List.last(filters).high_hz == 3400.0
    end

    test "refuses geometry that cannot produce sensible features" do
      assert_raise ArgumentError, fn -> Mfcc.mel_filterbank(1, @fft, @rate) end
      assert_raise ArgumentError, fn -> Mfcc.mel_filterbank(26, 513, @rate) end
      assert_raise ArgumentError, fn -> Mfcc.mel_filterbank(26, @fft, 0) end

      assert_raise ArgumentError, fn ->
        Mfcc.mel_filterbank(26, @fft, @rate, high_hz: 99_000.0)
      end

      assert_raise ArgumentError, fn ->
        Mfcc.mel_filterbank(26, @fft, @rate, low_hz: 5000.0, high_hz: 500.0)
      end
    end
  end

  describe "the bank is aligned to frequency" do
    test "a spike in one bin gives its largest band energy to the filter covering that bin" do
      %{filters: filters} = b = bank()

      # Skip the outermost filters: their triangles are clipped by DC and
      # Nyquist, so "the filter covering this bin" is genuinely ambiguous there.
      for filter <- Enum.slice(filters, 2..-3//1) do
        bin = bin_nearest(filter.center_hz)
        peaked_in = argmax(Mfcc.band_energies(spike(bin), b))

        assert peaked_in == filter.index,
               "a spike at bin #{bin} (#{bin * @rate / @fft} Hz) peaked in filter #{peaked_in}, " <>
                 "but that frequency is the centre of filter #{filter.index}"
      end
    end

    test "a spike below the first centre and above the last still lands at the ends" do
      %{filters: filters} = b = bank()
      first = List.first(filters)
      last = List.last(filters)

      assert argmax(Mfcc.band_energies(spike(bin_nearest(first.center_hz)), b)) == 0
      assert argmax(Mfcc.band_energies(spike(bin_nearest(last.center_hz)), b)) == 25
    end

    test "a spike outside a filter contributes nothing to it" do
      b = bank()
      filters = b.filters
      target = Enum.at(filters, 10)
      far = Enum.at(filters, 20)

      energies = Mfcc.band_energies(spike(bin_nearest(target.center_hz)), b)
      assert Enum.at(energies, far.index) == 1.0e-10
    end

    test "band energies use the power spectrum" do
      b = bank()
      bin = bin_nearest(Enum.at(b.filters, 10).center_hz)

      one = Mfcc.band_energies(spike(bin, 1.0), b) |> Enum.at(10)
      three = Mfcc.band_energies(spike(bin, 3.0), b) |> Enum.at(10)

      assert_in_delta three / one, 9.0, 1.0e-9
    end
  end

  describe "features/2" do
    test "returns thirteen finite coefficients" do
      features = Mfcc.features(broadband(1), bank())

      assert length(features) == 13
      assert Enum.all?(features, &is_float/1)
      assert Enum.all?(features, &(&1 == &1 and abs(&1) < 1.0e6))
    end

    test "a constant volume change moves coefficient 0 and nothing else" do
      b = bank()
      quiet = broadband(3)
      loud = Enum.map(quiet, &(&1 * 4.0))

      [q0 | q_rest] = Mfcc.features(quiet, b)
      [l0 | l_rest] = Mfcc.features(loud, b)

      Enum.zip(q_rest, l_rest)
      |> Enum.each(fn {q, l} -> assert_in_delta q, l, 1.0e-9 end)

      # Power scales by 16, so every log energy shifts by log(16); under the
      # orthonormal DCT-II that is a c0 shift of sqrt(n_filters) * log(16).
      expected = :math.sqrt(26) * :math.log(16.0)
      assert_in_delta l0 - q0, expected, 1.0e-9
      assert abs(l0 - q0) > 1.0
    end

    test "coefficient 0 is total log energy, up to the orthonormal scale factor" do
      b = bank()
      spectrum = broadband(5)

      logs = Mfcc.log_energies(spectrum, b)
      [c0 | _] = Mfcc.features(spectrum, b)

      assert_in_delta c0, Enum.sum(logs) / :math.sqrt(26), 1.0e-9
    end

    test "the DCT is orthonormal: it preserves the length of the log-energy vector" do
      b = Mfcc.new(fft_size: @fft, sample_rate: @rate, n_coeffs: 26)
      spectrum = broadband(7)

      logs = Mfcc.log_energies(spectrum, b)
      coeffs = Mfcc.features(spectrum, b)

      norm = fn v -> v |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt() end
      assert_in_delta norm.(coeffs), norm.(logs), 1.0e-9
    end

    test "accepts a bare filter list and agrees with the precomputed bank" do
      filters = Mfcc.mel_filterbank(26, @fft, @rate)
      spectrum = broadband(9)

      assert Mfcc.features(spectrum, filters) == Mfcc.features(spectrum, bank())
    end

    test "is deterministic" do
      b = bank()
      spectrum = broadband(11)

      assert Mfcc.features(spectrum, b) === Mfcc.features(spectrum, b)
      assert Mfcc.features(spectrum, b) === Mfcc.features(spectrum, bank())
    end

    test "refuses a spectrum from a different FFT size" do
      assert_raise ArgumentError, fn -> Mfcc.features(List.duplicate(1.0, 129), bank()) end
    end
  end

  describe "silence" do
    test "an all-zero spectrum does not raise and produces finite features" do
      features = Mfcc.features(List.duplicate(0.0, @bins), bank())

      assert length(features) == 13
      assert Enum.all?(features, &is_float/1)
      assert Enum.all?(features, &(&1 == &1))
      assert Enum.all?(features, &(abs(&1) < 1.0e6))
    end

    test "silence floors every band at the documented epsilon" do
      energies = Mfcc.band_energies(List.duplicate(0.0, @bins), bank())
      assert Enum.all?(energies, &(&1 == 1.0e-10))
    end

    test "silence is flat: only coefficient 0 is non-zero" do
      [c0 | rest] = Mfcc.features(List.duplicate(0.0, @bins), bank())

      assert_in_delta c0, :math.sqrt(26) * :math.log(1.0e-10), 1.0e-9
      assert Enum.all?(rest, &(abs(&1) < 1.0e-9))
    end

    test "a filter that catches no FFT bin is floored rather than fatal" do
      # 60 filters over a 128-point FFT leaves the low triangles narrower than
      # the 172 Hz bin spacing, so some of them cover nothing at all.
      tiny = Mfcc.new(n_filters: 60, n_coeffs: 13, fft_size: 128, sample_rate: @rate)
      assert Enum.any?(tiny.filters, &(&1.weights == []))

      features = Mfcc.features(List.duplicate(1.0, 65), tiny)
      assert length(features) == 13
      assert Enum.all?(features, &(&1 == &1))
    end
  end

  describe "cmn/1" do
    setup do
      b = bank()
      seq = Enum.map(1..20, fn i -> Mfcc.features(broadband(i), b) end)
      {:ok, seq: seq}
    end

    test "every coefficient's mean across the sequence is zero afterwards", %{seq: seq} do
      normalized = Mfcc.cmn(seq)

      sums =
        Enum.reduce(normalized, List.duplicate(0.0, 13), fn vec, acc ->
          Enum.zip_with(vec, acc, &(&1 + &2))
        end)

      Enum.each(sums, fn sum -> assert_in_delta sum / 20, 0.0, 1.0e-9 end)
    end

    test "keeps the shape of the sequence", %{seq: seq} do
      normalized = Mfcc.cmn(seq)
      assert length(normalized) == length(seq)
      assert Enum.all?(normalized, &(length(&1) == 13))
    end

    test "removes a constant channel offset exactly", %{seq: seq} do
      # A fixed filter is, after the log and the DCT, a constant added to every
      # frame. That is the whole reason this function exists.
      colour = Enum.map(1..13, fn i -> i * 0.37 end)
      coloured = Enum.map(seq, fn vec -> Enum.zip_with(vec, colour, &(&1 + &2)) end)

      Enum.zip(Mfcc.cmn(seq), Mfcc.cmn(coloured))
      |> Enum.each(fn {clean, tinted} ->
        Enum.zip(clean, tinted) |> Enum.each(fn {a, b} -> assert_in_delta a, b, 1.0e-9 end)
      end)
    end

    test "is idempotent", %{seq: seq} do
      once = Mfcc.cmn(seq)
      twice = Mfcc.cmn(once)

      Enum.zip(once, twice)
      |> Enum.each(fn {a, b} ->
        Enum.zip(a, b) |> Enum.each(fn {x, y} -> assert_in_delta x, y, 1.0e-9 end)
      end)
    end

    test "handles the degenerate sequences" do
      assert Mfcc.cmn([]) == []
      assert Mfcc.cmn([[1.0, 2.0, 3.0]]) == [[0.0, 0.0, 0.0]]
    end

    test "refuses a ragged sequence" do
      assert_raise ArgumentError, fn -> Mfcc.cmn([[1.0, 2.0], [3.0]]) end
    end
  end

  describe "deltas/1" do
    test "keeps the length and the dimension" do
      b = bank()
      seq = Enum.map(1..8, fn i -> Mfcc.features(broadband(i), b) end)
      d = Mfcc.deltas(seq)

      assert length(d) == 8
      assert Enum.all?(d, &(length(&1) == 13))
    end

    test "a constant sequence has no dynamics" do
      seq = List.duplicate([1.0, -2.0, 3.0], 5)
      assert Mfcc.deltas(seq) == List.duplicate([0.0, 0.0, 0.0], 5)
    end

    test "a linear ramp has a constant slope, ends included" do
      seq = Enum.map(0..5, fn t -> [t * 2.0] end)
      assert Mfcc.deltas(seq) == [[2.0], [2.0], [2.0], [2.0], [2.0], [2.0]]
    end

    test "handles the degenerate sequences" do
      assert Mfcc.deltas([]) == []
      assert Mfcc.deltas([[1.0, 2.0]]) == [[0.0, 0.0]]
    end

    test "with_deltas/1 concatenates statics and deltas" do
      b = bank()
      seq = Enum.map(1..4, fn i -> Mfcc.features(broadband(i), b) end)
      combined = Mfcc.with_deltas(seq)

      assert length(combined) == 4
      assert Enum.all?(combined, &(length(&1) == 26))
      assert Enum.zip(seq, combined) |> Enum.all?(fn {s, c} -> Enum.take(c, 13) == s end)
    end
  end

  describe "without_c0/1" do
    test "drops the loudness coefficient and leaves the shape" do
      b = bank()
      seq = [Mfcc.features(broadband(2), b)]

      assert [shape] = Mfcc.without_c0(seq)
      assert length(shape) == 12
      assert shape == tl(hd(seq))
    end

    test "makes a level change invisible" do
      b = bank()
      quiet = broadband(4)
      loud = Enum.map(quiet, &(&1 * 7.0))

      [a] = Mfcc.without_c0([Mfcc.features(quiet, b)])
      [c] = Mfcc.without_c0([Mfcc.features(loud, b)])

      Enum.zip(a, c) |> Enum.each(fn {x, y} -> assert_in_delta x, y, 1.0e-9 end)
    end
  end

  describe "new/1" do
    test "precomputes a reusable bank" do
      b = bank()

      assert b.n_filters == 26
      assert b.n_coeffs == 13
      assert b.n_bins == @bins
      assert b.filters == Mfcc.mel_filterbank(26, @fft, @rate)
      assert length(b.dct) == 13
      assert Enum.all?(b.dct, &(length(&1) == 26))
    end

    test "refuses more coefficients than filters" do
      assert_raise ArgumentError, fn -> Mfcc.new(n_filters: 10, n_coeffs: 13) end
      assert_raise ArgumentError, fn -> Mfcc.new(n_coeffs: 0) end
    end

    test "carries a restricted band through" do
      b = Mfcc.new(low_hz: 300.0, high_hz: 3400.0)
      assert b.low_hz == 300.0
      assert List.last(b.filters).high_hz == 3400.0
    end
  end
end
