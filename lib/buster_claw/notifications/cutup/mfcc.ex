defmodule BusterClaw.Notifications.Cutup.Mfcc do
  @moduledoc """
  Mel-frequency cepstral coefficients (STUDIO_ROADMAP Part III, Phase V.1) — the
  stage that turns an FFT magnitude spectrum into the handful of numbers DTW
  actually compares.

  `Signal` hands us a `t:BusterClaw.Notifications.Cutup.Types.spectrum/0`: 257
  magnitudes for a 512-point FFT, one per frequency bin. That is far too much
  detail to match on. Two takes of the same word by the same speaker differ in
  almost every bin — pitch drifts, the room rings differently, the handset rolls
  off somewhere else — while the thing that makes them *the same word*, the shape
  of the vocal tract over time, is a much coarser envelope. **MFCCs are that
  envelope, and throwing the rest away is the point rather than a lossy
  compromise.** Thirteen coefficients per 25 ms frame is what makes a
  1970s-vintage matcher work at all.

  The chain, and what each step buys:

      spectrum (257 magnitudes)
        └─ mel filterbank      → 26 band energies   (mel spacing ≈ how ears hear)
        └─ natural log         → 26 log energies    (loudness is multiplicative)
        └─ DCT-II, keep 13     → 13 coefficients    (decorrelate, keep the shape)
        └─ cepstral mean norm  → 13 coefficients    (delete the channel)

  **Mel spacing** puts roughly equal resolution per perceptual step, which is
  fine detail below 1 kHz and coarse detail above 4 kHz — the same trade hearing
  makes, and the reason a formant shift matters more than an equal-sized shift up
  in the harmonics. **The log** turns gain into an additive offset, which is what
  lets the next two steps subtract channel and level away instead of dividing
  them out. **The DCT** decorrelates the (heavily overlapping, therefore heavily
  correlated) bands and packs the envelope into the low coefficients, so keeping
  13 of 26 discards fine spectral ripple — mostly pitch harmonics, which we
  *want* gone: the same word at a different pitch should still match.

  ## Cepstral mean normalisation matters more here than anything else

  `cmn/1` subtracts each coefficient's mean across a whole recording. It is two
  lines of arithmetic and it is the single most important function in this
  module for our corpus.

  A telephone handset, a room, a codec and a distance-from-the-mouth are all,
  to a first approximation, a **fixed filter** applied to the whole recording.
  In the spectrum that filter is a multiplication; after the log it is a
  *constant added to every frame*; after the DCT it is a constant added to every
  coefficient. Subtracting the per-coefficient mean over the recording deletes
  it exactly.

  Skip it and DTW distance is dominated by **which phone the call came from**
  rather than **which word was said** — two takes of "harbor" from different
  calls score worse than "harbor" and "harder" from the same call, and no
  threshold can rescue that. Our corpus is voicemail: every recording is a
  different handset, a different line, a different distance. So: run `cmn/1`
  over the template and over the target recording, each against its own mean,
  before any DTW call.

  Its honest limit: the mean is only a fixed filter if the recording really is
  one channel throughout, and it needs enough frames to estimate. Over a
  three-second clip the mean is partly the *speech*, so CMN quietly removes some
  of the signal too. Prefer normalising over a whole recording and cutting the
  template out afterwards, rather than normalising a two-word snippet on its own.

  ## Coefficient 0: kept, and what that costs

  **We keep it.** `c0` is total log energy (loudness), not spectral shape, so
  keeping it makes DTW distance sensitive to level — and our callers stand at
  different distances from different handsets, so raw level is close to noise.

  The reason to keep it anyway is `cmn/1`: subtracting the recording's mean `c0`
  turns it from *absolute* loudness (noise) into *relative* loudness within this
  recording (signal — the energy contour of a word is genuinely discriminative,
  and it is what stops a whispered vowel matching a stressed one). Keeping it
  also means the vector is the 13 coefficients the type doc names, with no
  special case at the seam.

  If it turns out to hurt on the real corpus, `without_c0/1` drops it, and the
  matcher does not care: `t:BusterClaw.Notifications.Cutup.Types.features/0` is
  an opaque point in N-space, so a 12-dimensional vector is as valid as a
  13-dimensional one. **This is a knob to try during threshold tuning, not a
  decision to agonise over now.**

  ## Numbers pinned here, and why these ones

  - **26 filters.** The standard bank. Enough to resolve formants, few enough
    that each has several FFT bins in it at our rate.
  - **13 coefficients.** The standard keep. `c1..c12` is the envelope; above that
    is ripple that varies between two takes of the same word.
  - **Log floor `1.0e-10`.** `:math.log(0.0)` raises, and a band with no energy
    is not a corner case here — **real silence in a voicemail produces exactly
    zero**, as does any filter whose triangle happens to catch no FFT bin. We
    clamp the *energy* at `1.0e-10` (so `log` bottoms out near `-23.03`) rather
    than adding an epsilon to every band, because a floor leaves ordinary values
    bit-identical and only touches the ones that would raise.
  - **Power, not magnitude.** The input contract is magnitudes; we square them
    before the filterbank, which is the conventional definition. It only scales
    every coefficient by two in the log domain, so nothing downstream can tell —
    but "conventional" is worth more than "one multiply cheaper" when someone
    later compares these numbers against a reference implementation.
  - **Unit-peak (HTK-style) triangles.** Each filter peaks at exactly `1.0` at
    its centre. The alternative (Slaney's, area-normalised) divides by bandwidth,
    which tilts the whole spectrum down at high frequencies. Neither is wrong;
    they are not interchangeable, and mixing them between a stored template and a
    fresh recording would be silently catastrophic.

  ## The filterbank is built once and held

  `new/1` returns a `%#{inspect(__MODULE__)}{}` carrying the filters *and* the
  precomputed DCT basis. **Hold it and pass it to every frame.** The corpus is
  ~30,000 frames; rebuilding a 26-filter bank and a 13×26 cosine table per frame
  is the obvious way to make this module look like the BEAM's fault. `features/2`
  also accepts a bare filter list for convenience, and that path rebuilds the
  DCT basis every call — it exists for tests, not for indexing.

  ## What this module deliberately does not do

  - **No pre-emphasis, no windowing, no FFT.** Those are `Signal`'s, upstream.
  - **No cepstral liftering.** HTK's lifter exists to balance coefficient
    variances for diagonal-covariance GMMs; we have no GMM. It is still true
    that plain Euclidean distance lets whichever coefficient has the largest
    spread dominate, so if threshold tuning stalls, per-coefficient variance
    normalisation (or a lifter) is the next lever — measured against the real
    corpus, not guessed at here.
  - **No energy term, no VAD.** Frames of pure silence produce perfectly valid,
    perfectly meaningless features. Deciding which frames are speech is `Vad`'s
    job (Phase V.3).

  ## Deltas: implemented, and recommended *off*

  `deltas/1` and `with_deltas/1` compute first-order differences across time.
  The argument for them is that a static frame says nothing about *direction* —
  a rising and a falling formant can look identical frame by frame — and DTW
  compares frames independently, so it does not recover that on its own; warping
  time is not the same as modelling change over time.

  The argument against, which we take: deltas double the dimension (and so the
  DTW cost), they live on a **different numeric scale** than the static
  coefficients, so an unweighted Euclidean distance silently reweights the
  vector by whatever that ratio happens to be, and DTW's own path continuity
  already couples neighbouring frames enough to blunt the gain. **Leave them off,
  get a working threshold on 13 static coefficients first, and only reach for
  `with_deltas/1` if confusions turn out to be between words with the same
  spectral shape in a different order** — and if you do, scale them before
  trusting the distance.
  """

  alias BusterClaw.Notifications.Cutup.Types

  @default_filters 26
  @default_coeffs 13
  @default_fft 512
  @default_rate 22_050

  # Band energies below this are clamped before the log. See the moduledoc:
  # silence is common, not exotic, and `:math.log(0.0)` raises.
  @log_floor 1.0e-10

  defstruct n_filters: @default_filters,
            n_coeffs: @default_coeffs,
            fft_size: @default_fft,
            sample_rate: @default_rate,
            n_bins: div(@default_fft, 2) + 1,
            low_hz: 0.0,
            high_hz: @default_rate / 2,
            filters: [],
            dct: []

  @typedoc """
  One triangular filter.

  `weights` is **sparse and bin-ordered**: only the FFT bins the triangle
  actually covers, as `{bin_index, weight}`. Sparse because a filter touches a
  handful of the 257 bins and the dense form would be 97% zeros multiplied
  30,000 times.

  The three frequencies are the triangle's corners in Hz. `center_hz` is where
  the weight is `1.0`; the weight falls linearly *in frequency* (not in mel) to
  zero at `low_hz` and `high_hz`.
  """
  @type filter :: %{
          index: non_neg_integer(),
          low_hz: float(),
          center_hz: float(),
          high_hz: float(),
          weights: [{non_neg_integer(), float()}]
        }

  @typedoc """
  A precomputed extractor: the filterbank, the DCT basis, and the geometry both
  were built for. Build one with `new/1` and reuse it for every frame.

  It carries `fft_size`/`sample_rate` so `features/2` can *check* that the
  spectrum it was handed came from the same geometry. A bank built for one FFT
  size applied to another produces features that are wrong but entirely
  plausible-looking, which is the worst failure mode available here.
  """
  @type t :: %__MODULE__{
          n_filters: pos_integer(),
          n_coeffs: pos_integer(),
          fft_size: pos_integer(),
          sample_rate: pos_integer(),
          n_bins: pos_integer(),
          low_hz: float(),
          high_hz: float(),
          filters: [filter()],
          dct: [[float()]]
        }

  # ---------------------------------------------------------------------------
  # The mel scale
  # ---------------------------------------------------------------------------

  @doc """
  Hz → mel, `2595 * log10(1 + f / 700)`.

  The O'Shaughnessy constants, which is the version everyone else in speech uses.
  It is a curve fitted to listening experiments, not a law: below 700 Hz it is
  near-linear, above it near-logarithmic. Monotonic, and `hz_to_mel(0.0) == 0.0`.
  """
  @spec hz_to_mel(number()) :: float()
  def hz_to_mel(hz) when is_number(hz), do: 2595.0 * :math.log10(1.0 + hz / 700.0)

  @doc "mel → Hz, the exact inverse of `hz_to_mel/1`."
  @spec mel_to_hz(number()) :: float()
  def mel_to_hz(mel) when is_number(mel), do: 700.0 * (:math.pow(10.0, mel / 2595.0) - 1.0)

  # ---------------------------------------------------------------------------
  # The filterbank
  # ---------------------------------------------------------------------------

  @doc """
  Build `n_filters` triangular filters, equally spaced **on the mel scale**,
  spanning DC to Nyquist.

  Centres are `n_filters + 2` equally spaced mel points mapped back to Hz; filter
  `i` runs from centre `i` to centre `i + 2` and peaks at centre `i + 1`. So
  every filter overlaps both neighbours by exactly half its width, and the bank
  tiles the band with no holes — a gap between filters would be a frequency range
  no coefficient can see.

  Weights are evaluated at each bin's true centre frequency, `k * sample_rate /
  fft_size`, rather than by rounding corner frequencies to bins first. The
  rounding version is common and is off by up to half a bin at the bottom of the
  bank, where half a bin is a large fraction of a filter.

  Result is a plain list, safe to hold and reuse. Prefer `new/1`, which also
  precomputes the DCT basis.
  """
  @spec mel_filterbank(pos_integer(), pos_integer(), pos_integer()) :: [filter()]
  def mel_filterbank(n_filters, fft_size, sample_rate) do
    mel_filterbank(n_filters, fft_size, sample_rate, [])
  end

  @doc """
  As `mel_filterbank/3`, with `:low_hz` and `:high_hz` to restrict the band.

  Worth knowing for telephony: an 8 kHz line carries roughly 300–3400 Hz and the
  bands outside that hold nothing but noise, so spending filters on them spends
  resolution on nothing. Both default to the full range (0 to Nyquist) because
  our internal format is 22.05 kHz and the sources are mixed.
  """
  @spec mel_filterbank(pos_integer(), pos_integer(), pos_integer(), keyword()) :: [filter()]
  def mel_filterbank(n_filters, fft_size, sample_rate, opts) when is_list(opts) do
    nyquist = sample_rate / 2.0
    low_hz = 1.0 * Keyword.get(opts, :low_hz, 0.0)
    high_hz = 1.0 * Keyword.get(opts, :high_hz, nyquist)

    validate_geometry!(n_filters, fft_size, sample_rate, low_hz, high_hz)

    corners = mel_corners(n_filters, low_hz, high_hz)
    bin_hz = sample_rate / fft_size
    n_bins = div(fft_size, 2) + 1

    corners
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.with_index()
    |> Enum.map(fn {[lo, ctr, hi], index} -> triangle(index, lo, ctr, hi, {n_bins, bin_hz}) end)
  end

  @doc """
  A ready-to-use extractor: filterbank plus DCT basis, built once.

  Options (all with the standard defaults): `:n_filters` (26), `:n_coeffs` (13),
  `:fft_size` (512), `:sample_rate` (22_050), `:low_hz`, `:high_hz`.

  Raises `ArgumentError` on a geometry that cannot produce sensible features —
  more coefficients than filters, an odd FFT size, a band running past Nyquist.
  These are all mistakes that otherwise surface as features that are merely
  wrong.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    n_filters = Keyword.get(opts, :n_filters, @default_filters)
    n_coeffs = Keyword.get(opts, :n_coeffs, @default_coeffs)
    fft_size = Keyword.get(opts, :fft_size, @default_fft)
    sample_rate = Keyword.get(opts, :sample_rate, @default_rate)
    low_hz = 1.0 * Keyword.get(opts, :low_hz, 0.0)
    high_hz = 1.0 * Keyword.get(opts, :high_hz, sample_rate / 2.0)

    validate_coeffs!(n_coeffs, n_filters)
    filters = mel_filterbank(n_filters, fft_size, sample_rate, low_hz: low_hz, high_hz: high_hz)

    %__MODULE__{
      n_filters: n_filters,
      n_coeffs: n_coeffs,
      fft_size: fft_size,
      sample_rate: sample_rate,
      n_bins: div(fft_size, 2) + 1,
      low_hz: low_hz,
      high_hz: high_hz,
      filters: filters,
      dct: dct_basis(n_coeffs, n_filters)
    }
  end

  # ---------------------------------------------------------------------------
  # Features
  # ---------------------------------------------------------------------------

  @doc """
  One spectrum in, one feature vector out: filterbank → log → DCT-II → keep 13.

  `bank` should be a `t:t/0` from `new/1`. A bare filter list also works and
  rebuilds the DCT basis on every call — fine for a test, wasteful for 30,000
  frames.

  ## The DCT-II scaling convention

  **Orthonormal** (`scipy`'s `norm: :ortho`, `Nx`'s default):

      c_k = a_k * Σ_{n=0}^{N-1} x_n * cos(π * (n + 0.5) * k / N)
      a_0 = sqrt(1 / N)      a_k = sqrt(2 / N) for k > 0

  Orthonormal because it makes the transform an isometry: distances between log
  spectra equal distances between cepstra, so a DTW threshold means the same
  thing on either side of the DCT. The unscaled variant leaves `c0` a factor of
  `sqrt(2)` out of step with the rest — small enough to look fine and large
  enough to skew every distance. **Pick one and never mix**; a template stored
  under one convention and a recording analysed under the other will not match.

  Under this convention `c0 = sqrt(N) * mean(log energies)`, i.e. total loudness.
  See the moduledoc on why we keep it.
  """
  @spec features(Types.spectrum(), t() | [filter()]) :: Types.features()
  def features(spectrum, %__MODULE__{} = bank) do
    spectrum
    |> log_energies(bank)
    |> apply_dct(bank.dct)
  end

  def features(spectrum, filters) when is_list(filters) do
    n_filters = length(filters)
    n_coeffs = min(@default_coeffs, n_filters)

    spectrum
    |> log_energies(filters)
    |> apply_dct(dct_basis(n_coeffs, n_filters))
  end

  @doc """
  The filterbank alone: one energy per band, before the log.

  Exposed because it is the seam worth testing (does a tone land in the filter
  the mel scale says it should?) and because a later VAD or a display might want
  band energies without the cepstral half.

  Energies are of the **power** spectrum — each magnitude squared — and are
  clamped at `#{@log_floor}` on the way out so the caller cannot hand a zero to a
  logarithm.
  """
  @spec band_energies(Types.spectrum(), t() | [filter()]) :: [float()]
  def band_energies(spectrum, %__MODULE__{} = bank) do
    check_bins!(length(spectrum), bank.n_bins)
    energies(spectrum, bank.filters)
  end

  def band_energies(spectrum, filters) when is_list(filters) do
    check_bins!(length(spectrum), max_bin(filters) + 1, :at_least)
    energies(spectrum, filters)
  end

  @doc "Band energies, logged. `features/2` is this followed by the DCT."
  @spec log_energies(Types.spectrum(), t() | [filter()]) :: [float()]
  def log_energies(spectrum, bank) do
    spectrum |> band_energies(bank) |> Enum.map(&:math.log/1)
  end

  # ---------------------------------------------------------------------------
  # Sequence-level operations
  # ---------------------------------------------------------------------------

  @doc """
  Cepstral mean normalisation: subtract each coefficient's mean across the whole
  sequence.

  **Run this on every recording and every template before comparing them** — see
  the moduledoc. Each sequence is normalised against *its own* mean; that is the
  entire mechanism, since the mean is the channel.

  An empty sequence returns empty. A single frame returns a zero vector, which
  is correct and useless: with one frame the mean *is* the frame. Raises if the
  frames are not all the same length.
  """
  @spec cmn(Types.feature_seq()) :: Types.feature_seq()
  def cmn([]), do: []

  def cmn([first | _] = seq) when is_list(first) do
    dim = length(first)
    count = length(seq)
    validate_uniform!(seq, dim)

    zeros = List.duplicate(0.0, dim)
    sums = Enum.reduce(seq, zeros, fn vec, acc -> Enum.zip_with(vec, acc, &(&1 + &2)) end)
    means = Enum.map(sums, &(&1 / count))

    Enum.map(seq, fn vec -> Enum.zip_with(vec, means, &(&1 - &2)) end)
  end

  @doc """
  First-order differences across time — one delta vector per frame, same
  dimension as the input.

  Symmetric central difference, `(c[t+1] - c[t-1]) / 2`, with the ends held
  (the first and last frames use a one-sided difference) so the sequence keeps
  its length and frame `i` still means `i * hop_ms`. A sequence shorter than two
  frames has no dynamics and comes back as zeros.

  **Recommended off by default** — see the moduledoc for the reasoning.
  """
  @spec deltas(Types.feature_seq()) :: Types.feature_seq()
  def deltas([]), do: []

  def deltas([only]) when is_list(only), do: [List.duplicate(0.0, length(only))]

  def deltas([first | _] = seq) when is_list(first) do
    validate_uniform!(seq, length(first))
    frames = List.to_tuple(seq)
    last = tuple_size(frames) - 1

    Enum.map(0..last, fn t ->
      prev = elem(frames, max(t - 1, 0))
      next = elem(frames, min(t + 1, last))
      scale = if t == 0 or t == last, do: 1.0, else: 2.0
      Enum.zip_with(next, prev, &((&1 - &2) / scale))
    end)
  end

  @doc """
  Each frame's static coefficients concatenated with its deltas — 26 dimensions
  from 13.

  Note the scale mismatch called out in the moduledoc: deltas are differences
  and are numerically much smaller than the statics, so an unweighted distance
  over the concatenation is not an equal-weight distance. Off by default.
  """
  @spec with_deltas(Types.feature_seq()) :: Types.feature_seq()
  def with_deltas(seq) do
    seq |> Enum.zip(deltas(seq)) |> Enum.map(fn {static, delta} -> static ++ delta end)
  end

  @doc """
  Drop coefficient 0 from every frame, leaving 12 shape-only coefficients.

  The lever described in the moduledoc: this buys invariance to level (callers
  at different distances from different handsets) at the cost of the energy
  contour. Try it during threshold tuning; the matcher does not need to know.
  """
  @spec without_c0(Types.feature_seq()) :: Types.feature_seq()
  def without_c0(seq), do: Enum.map(seq, fn [_c0 | rest] -> rest end)

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp mel_corners(n_filters, low_hz, high_hz) do
    low_mel = hz_to_mel(low_hz)
    high_mel = hz_to_mel(high_hz)
    step = (high_mel - low_mel) / (n_filters + 1)
    last = n_filters + 1

    Enum.map(0..last, fn
      0 -> low_hz
      ^last -> high_hz
      i -> mel_to_hz(low_mel + i * step)
    end)
  end

  # The `mel_to_hz(hz_to_mel(x))` round trip is accurate to ~1e-12 relative, but
  # the endpoints are substituted exactly rather than round-tripped: the top
  # corner is Nyquist, and "the bank covers up to Nyquist without exceeding it"
  # should be true by construction rather than to within float luck.
  defp triangle(index, low_hz, center_hz, high_hz, {n_bins, bin_hz}) do
    weights =
      0..(n_bins - 1)
      |> Enum.map(fn bin -> {bin, weight_at(bin * bin_hz, low_hz, center_hz, high_hz)} end)
      |> Enum.filter(fn {_bin, w} -> w > 0.0 end)

    %{
      index: index,
      low_hz: low_hz,
      center_hz: center_hz,
      high_hz: high_hz,
      weights: weights
    }
  end

  defp weight_at(hz, low_hz, center_hz, high_hz) do
    cond do
      hz <= low_hz or hz >= high_hz -> 0.0
      hz <= center_hz -> (hz - low_hz) / (center_hz - low_hz)
      true -> (high_hz - hz) / (high_hz - center_hz)
    end
  end

  defp dct_basis(n_coeffs, n_filters) do
    Enum.map(0..(n_coeffs - 1), fn k ->
      alpha = if k == 0, do: :math.sqrt(1.0 / n_filters), else: :math.sqrt(2.0 / n_filters)

      Enum.map(0..(n_filters - 1), fn n ->
        alpha * :math.cos(:math.pi() * (n + 0.5) * k / n_filters)
      end)
    end)
  end

  defp apply_dct(logs, basis) do
    Enum.map(basis, fn row -> Enum.zip_reduce(row, logs, 0.0, fn b, x, acc -> acc + b * x end) end)
  end

  # Squared once per bin, not once per filter: the triangles overlap, so every
  # bin is read by two filters and squaring inside the inner loop would double
  # the multiplications in the hottest function in the module.
  defp energies(spectrum, filters) do
    powers = spectrum |> Enum.map(&(&1 * &1)) |> List.to_tuple()

    Enum.map(filters, fn %{weights: weights} ->
      weights
      |> Enum.reduce(0.0, fn {bin, w}, acc -> acc + w * elem(powers, bin) end)
      |> floor_energy()
    end)
  end

  defp floor_energy(energy) when energy > @log_floor, do: energy
  defp floor_energy(_energy), do: @log_floor

  defp max_bin(filters) do
    filters
    |> Enum.flat_map(fn %{weights: weights} -> Enum.map(weights, &elem(&1, 0)) end)
    |> Enum.max(fn -> 0 end)
  end

  defp check_bins!(got, want, mode \\ :exactly)
  defp check_bins!(got, want, :exactly) when got == want, do: :ok
  defp check_bins!(got, want, :at_least) when got >= want, do: :ok

  defp check_bins!(got, want, mode) do
    raise ArgumentError,
          "spectrum has #{got} bins but the filterbank needs #{mode} #{want}; " <>
            "the bank and the FFT must be built for the same fft_size and sample_rate"
  end

  defp validate_geometry!(n_filters, fft_size, sample_rate, low_hz, high_hz) do
    nyquist = sample_rate / 2.0

    cond do
      not (is_integer(n_filters) and n_filters >= 2) ->
        raise ArgumentError, "n_filters must be an integer >= 2, got: #{inspect(n_filters)}"

      not (is_integer(fft_size) and fft_size >= 4 and rem(fft_size, 2) == 0) ->
        raise ArgumentError, "fft_size must be an even integer >= 4, got: #{inspect(fft_size)}"

      not (is_integer(sample_rate) and sample_rate > 0) ->
        raise ArgumentError,
              "sample_rate must be a positive integer, got: #{inspect(sample_rate)}"

      low_hz < 0.0 or high_hz > nyquist or low_hz >= high_hz ->
        raise ArgumentError,
              "the band #{low_hz}..#{high_hz} Hz must satisfy 0 <= low < high <= #{nyquist} (Nyquist)"

      true ->
        :ok
    end
  end

  defp validate_coeffs!(n_coeffs, n_filters) do
    if is_integer(n_coeffs) and n_coeffs >= 1 and n_coeffs <= n_filters do
      :ok
    else
      raise ArgumentError,
            "n_coeffs must be an integer in 1..n_filters (#{inspect(n_filters)}), " <>
              "got: #{inspect(n_coeffs)}"
    end
  end

  defp validate_uniform!(seq, dim) do
    if Enum.all?(seq, fn vec -> is_list(vec) and length(vec) == dim end) do
      :ok
    else
      raise ArgumentError,
            "every feature vector in a sequence must have the same length (#{dim}); " <>
              "a ragged sequence means two different extractors produced it"
    end
  end
end
