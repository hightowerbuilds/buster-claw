defmodule BusterClaw.Notifications.Cutup.Signal.Tables do
  @moduledoc false
  #
  # Table builders, in their own module for one boring compiler reason: a module
  # attribute is evaluated while its own module is still being compiled, so
  # `Signal` cannot call `Signal.twiddles/1` to fill `@twiddles`. Splitting the
  # builders out lets the *same* code serve both the compile-time cache and the
  # runtime fallback for an uncached size, instead of two copies drifting apart.
  #
  # Nothing here is on a hot path — every function is called once per FFT size,
  # or once per `frames/2` call — so it is written for clarity, not speed.

  @doc false
  @spec twiddles(pos_integer()) :: tuple()
  def twiddles(n) when n >= 2 do
    entries =
      for i <- 0..(div(n, 2) - 1) do
        angle = -2.0 * :math.pi() * i / n
        {:math.cos(angle), :math.sin(angle)}
      end

    List.to_tuple(entries)
  end

  @doc false
  @spec bit_reversal(pos_integer()) :: tuple()
  def bit_reversal(n) when n >= 2 do
    bits = bit_width(n)
    List.to_tuple(Enum.map(0..(n - 1), &reverse_bits(&1, bits)))
  end

  @doc """
  A symmetric Hamming window: `0.54 - 0.46*cos(2*pi*n/(len-1))`.

  The **symmetric** form (denominator `len - 1`, not `len`), so the endpoints are
  exactly 0.08. That is the convention every MFCC reference uses; the periodic
  form belongs to overlap-add resynthesis, which this pipeline never does.
  """
  @spec hamming(pos_integer()) :: [float()]
  def hamming(1), do: [1.0]

  def hamming(len) when len > 1 do
    for n <- 0..(len - 1), do: 0.54 - 0.46 * :math.cos(2.0 * :math.pi() * n / (len - 1))
  end

  @doc false
  @spec bit_width(pos_integer()) :: non_neg_integer()
  def bit_width(n) when n >= 1, do: bit_width(n, 0)

  defp bit_width(1, acc), do: acc
  defp bit_width(n, acc), do: bit_width(div(n, 2), acc + 1)

  # Reverse the low `bits` bits of `i`. Each pass shifts the accumulator left one
  # place and drops in the next-lowest bit of `i`, so bit 0 ends up as the MSB.
  defp reverse_bits(i, bits) do
    Enum.reduce(0..(bits - 1), 0, fn b, acc -> acc * 2 + rem(div(i, Integer.pow(2, b)), 2) end)
  end
end

defmodule BusterClaw.Notifications.Cutup.Signal do
  @moduledoc """
  The signal floor of the cut-up recogniser (STUDIO_ROADMAP Part III, phase V.0):
  turn a PCM16 clip into overlapping windowed frames, and turn one frame into a
  magnitude spectrum. Nothing above this line knows what a sample is; nothing
  below it knows what a word is.

  Pure arithmetic, **zero dependencies** — no Nx, no NIF, no port, no subprocess.
  That is not minimalism for its own sake. The last audio-ML attempt in this
  project died on the Apple code-signing path (a bundled model, a static native
  build, an unproven entitlement gamble), and the whole reason Part III is
  buildable at all is that classical DSP touches none of it.

  ## The frame geometry is fixed, and it is the clock

  **25 ms frames at a 10 ms hop**, pinned in `Cutup.Types` rather than passed
  around. A template extracted at one hop and a recording analysed at another
  cannot be compared at all, so these are not options. `frame_index_to_ms/1` is
  the *only* thing that converts a feature index back into a splice point, which
  makes it the single most load-bearing arithmetic in the pipeline.

  **Frame `i` starts at sample `round(i * hop_ms * rate / 1000)`, recomputed from
  the index every time — never by adding a fixed integer stride.** At 22.05 kHz a
  10 ms hop is 220.5 samples. Rounding that to 221 once and stepping by it looks
  identical for ten frames and is wrong by 0.23% forever: over the 295-second
  corpus the frame clock would drift two thirds of a second away from the audio
  clock, and every splice point at the end of a long recording would land in the
  wrong syllable. Recomputing from the index keeps the error bounded at half a
  sample (0.023 ms) and, crucially, **non-accumulating**.

  ## Pre-emphasis, and why it is not optional polish

  `y[n] = x[n] - 0.97*x[n-1]` — a one-tap high-pass applied before windowing.
  Voiced speech leaves the glottis with a spectral tilt of roughly -6 dB per
  octave (the source spectrum falls off; lip radiation only gives ~+6 dB back at
  the top). Left alone, the first formant carries so much more energy than the
  third and fourth that the mel filterbank's upper bands sit in the noise, and
  MFCCs computed from them are dominated by the speaker's pitch and loudness
  rather than by *which vowel it is*. Flattening the tilt is what makes the
  higher formants — the part that distinguishes one word from another — survive
  into the feature vector.

  The filter runs **across frame boundaries**, not within them: frame `i` reads
  the sample immediately before its own start for `x[n-1]`, so the result is
  identical to filtering the whole clip and framing afterwards. Restarting the
  filter at each frame would put a spurious transient in every frame's first
  sample, 100 times a second.

  ## How complex numbers are represented, and why

  A complex value is a **bare `{re, im}` two-tuple**, and one FFT working set is a
  **tuple of those tuples** — read with `elem/2`, which is O(1) on a tuple.

  The alternatives were considered and rejected for concrete reasons:

  - **A list with `Enum.at/2`** is O(n) per access, making the butterfly loop
    O(n^2). At n = 1024 that is ~500x more work per stage. Not viable, and it is
    the obvious wrong turn, so it is named here.
  - **`:array`** gives O(log n) get *and* set, and would let the butterflies be
    written in the textbook in-place form. But in-place is exactly what the BEAM
    cannot do: every `:array.set/3` rebuilds a path through the tree, so a
    "destructive" 1024-point FFT would allocate ~20,000 times per frame.
  - **A tuple rebuilt once per stage** (what this does) allocates `log2(n)` times
    per frame instead — 10 tuple builds for n = 1024. Each stage reads the
    previous stage's tuple in O(1) and emits its output as a cons list built in
    order, which is the one thing the BEAM is genuinely fast at, then converts
    that list to a tuple in a single pass.

  The twiddle factors and the bit-reversal permutation are **precomputed into
  module attributes at compile time** for every FFT size the pipeline actually
  uses. They are pure functions of `n`, they would otherwise be rebuilt 30,000
  times over a corpus index, and 512 `:math.cos/1` calls per frame is not a cost
  worth paying twice. An uncached size still works — it falls back to building
  the tables at runtime — which keeps small sizes usable in tests without
  special-casing them.

  ## The FFT is iterative, and it is unscaled

  Bit-reversal permutation, then `log2(n)` decimation-in-time butterfly stages.
  The recursive even/odd formulation is prettier and allocates a fresh list per
  recursion *level per subproblem*; the iterative form allocates one list per
  level total.

  **No `1/N` factor is applied anywhere.** So a DC input of `n` ones gives
  `X[0] = n`, and a sine of amplitude `a` at a bin centre gives a magnitude of
  `a*n/2`. Parseval's theorem therefore reads, for the half-spectrum this
  returns:

      sum(x[n]^2) == (|X[0]|^2 + |X[N/2]|^2 + 2*sum(|X[k]|^2 for k in 1..N/2-1)) / N

  That identity is the strongest single check on an FFT — it catches scaling and
  ordering errors that the single-spike tests sail straight past — and it is
  written here rather than only in the test file because anything computing frame
  energy from a spectrum needs the `2*` and the `/N`.

  ## Only magnitudes survive

  `spectrum/1` returns `n/2 + 1` magnitudes, DC through Nyquist inclusive. Phase
  is discarded at this boundary because nothing downstream — mel filterbank, log,
  DCT, DTW — has any use for it. Half the data crosses the seam, and the MFCC
  stage has half as much to reason about.

  **Magnitude — `sqrt(re^2 + im^2)` — not power, not dB.** `Mfcc` squares these
  itself, per the conventional definition. This is the one convention in the
  pipeline with no failure mode: returning power instead would shift every
  log-domain feature by a constant, crash nothing, and fail no test on either
  side of the seam alone. The only symptom would be a template stored under one
  convention quietly ceasing to match a recording analysed under the other,
  months later, presenting as "the matcher just isn't very good". So it is
  asserted against the analytic value in the test suite rather than left to
  documentation.

  ## Honest about the cost

  A pure-Elixir FFT is roughly two orders of magnitude slower than C: no SIMD,
  boxed floats, and an allocation for every complex intermediate. Measured on the
  development machine (M-series, OTP 27, `fft_size: 1024`, 22.05 kHz):

  | | frames/s |
  |---|---|
  | `frames/2` alone | ~10,000–15,000 |
  | `spectrum/1` alone (1024-point) | ~700–800 (≈1.4 ms/frame) |
  | end to end, clips up to a few seconds | ~750–790 |
  | end to end, a 10 s clip | ~300 |

  So the 295-second corpus (~29,500 frames) is **≈40 s single-core** on short
  files, and **≈27 s across 8 cores** with `Task.async_stream`. **The roadmap's
  "tens of seconds, parallelised, once" estimate holds** — which is worth stating
  because it holds *despite* the roadmap costing a 512-point transform: a 25 ms
  frame at 22.05 kHz is 551 samples, so the smallest radix-2 size that holds one
  without truncating is 1024, and the real work is about 2.2x the roadmap's
  figure. The estimate survived because it was pessimistic about per-operation
  cost by about the same factor. An index is saved and never silently recomputed,
  so this is a build cost, not a search cost.

  **The one measured surprise, and it matters to whoever writes the indexer:
  throughput halves on long clips.** `frames/2` is eager, so a 10-second clip
  leaves ~1M live floats on the process heap and every subsequent GC has to walk
  them; the same audio cut into 3-second pieces runs 2.5x faster. **Index one
  file per process and prefer short files**; do not accumulate a whole corpus of
  frames in one process before transforming them. Past roughly an hour of audio
  the whole approach stops being tolerable and the answer is `Nx`, not a rewrite —
  the pipeline is already frame-parallel arithmetic.

  ## Limits worth stating plainly

  - **Mono PCM16 only.** The studio's internal format is the only input; anything
    else is refused by name rather than silently mis-decoded.
  - **A clip shorter than one 25 ms frame yields zero frames**, not a padded one.
    See `frames/2` for why that is the honest answer.
  - **Nothing here is a detector.** These are numbers about sound. Deciding that
    a span is speech, or that two spans are the same word, is `Vad` and `Dtw`.
  """

  alias BusterClaw.Notifications.Cutup.Signal.Tables
  alias BusterClaw.Notifications.Cutup.Types
  alias BusterClaw.Notifications.SoundStudio

  # Pinned by Cutup.Types. Changing either invalidates every stored index.
  @frame_ms 25.0
  @hop_ms 10.0

  # The standard pre-emphasis coefficient. 0.95-0.97 is the usual range; 0.97 is
  # what HTK, Kaldi and every MFCC paper of the era use, and matching them means
  # published intuitions about filterbank shape still apply here.
  @pre_emphasis 0.97

  # 25 ms at 22.05 kHz is 551 samples, so 512 truncates and 1024 is the smallest
  # radix-2 size that holds a frame. See the moduledoc's note on the roadmap's
  # estimate, which assumed 512.
  @default_fft_size 1024

  # int16's negative rail is -32768 and its positive rail is +32767. Dividing by
  # 32768 maps the negative rail to exactly -1.0 and leaves the positive one one
  # step short, which is the standard asymmetry; dividing by 32767 instead would
  # let a full-scale negative sample exceed -1.0. Either is defensible, this one
  # is bounded.
  @full_scale 32_768.0

  # Every size the pipeline can reach in practice, plus the small ones tests use.
  # Uncached sizes still work; they just rebuild their tables per call.
  @cached_sizes [2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096]
  @twiddles Map.new(@cached_sizes, fn n -> {n, Tables.twiddles(n)} end)
  @bit_reversal Map.new(@cached_sizes, fn n -> {n, Tables.bit_reversal(n)} end)

  @typedoc """
  Options for `frames/2`.

  - `:fft_size` — the power-of-two length each frame is zero-padded to. Must be
    at least the frame length in samples or the call is refused.
  - `:pre_emphasis` — the filter coefficient. `0.0` disables the filter, which is
    occasionally useful for isolating it in a test and never useful in anger.
  """
  @type opts :: [fft_size: pos_integer(), pre_emphasis: float()]

  @doc "The analysis frame length in milliseconds. Fixed at 25.0 by `Cutup.Types`."
  @spec frame_ms() :: float()
  def frame_ms, do: @frame_ms

  @doc "The hop between consecutive frames in milliseconds. Fixed at 10.0 by `Cutup.Types`."
  @spec hop_ms() :: float()
  def hop_ms, do: @hop_ms

  @doc "The FFT size `frames/2` pads to unless told otherwise."
  @spec default_fft_size() :: pos_integer()
  def default_fft_size, do: @default_fft_size

  @doc """
  The start time of frame `index`, in milliseconds from the start of the clip.

  **This is the only function that converts a feature index back into a splice
  point**, so it is deliberately trivial and exactly `index * hop_ms`. The
  framing in `frames/2` is built to make that true rather than approximately
  true: see the moduledoc on why the sample offset is recomputed from the index
  instead of accumulated.

  It reports a frame's **start**, not its centre. A frame covers
  `[t, t + frame_ms)`, so a hit spanning frames `a..b` occupies
  `frame_index_to_ms(a)` to `frame_index_to_ms(b) + frame_ms`.
  """
  @spec frame_index_to_ms(non_neg_integer()) :: float()
  def frame_index_to_ms(index) when is_integer(index) and index >= 0, do: index * @hop_ms

  @doc """
  Cut a clip into overlapping, pre-emphasised, Hamming-windowed, zero-padded
  frames.

  Each returned frame is `fft_size` floats long: `round(25 ms * rate)` real
  samples followed by zeros, ready to hand straight to `spectrum/1`.

  ## What a frame contains, in order

  1. PCM16 decoded to floats in `-1.0..1.0` (divided by 32768).
  2. Pre-emphasis `y[n] = x[n] - 0.97*x[n-1]`, reading the sample immediately
     before the frame's own start so the filter is continuous over the whole
     clip rather than restarting 100 times a second.
  3. A symmetric Hamming window. Cutting a rectangle out of a waveform makes two
     step discontinuities, and a step is broadband — its leakage smears energy
     across every bin and swamps the formant structure the whole pipeline is
     looking for. The window tapers those edges to 0.08 of full scale.
  4. Zeros out to `fft_size`. Padding does not add information; it interpolates
     the spectrum onto a finer bin grid, which is exactly what is wanted when the
     natural frame length is not a power of two.

  ## Short clips yield zero frames, on purpose

  A clip shorter than one 25 ms frame returns `[]`. The alternative — one frame
  padded out with silence — produces a spectrum dominated by the padding and an
  energy that is not comparable with any other frame's, which would quietly
  poison a VAD threshold or a DTW distance. A caller that wants to analyse a
  10 ms clip has a problem this module cannot honestly solve for it.

  The same rule applies at the tail: the last partial frame is dropped, so a
  clip yields the frames whose full 25 ms window fits inside it.

  ## Refusals

  Raises `ArgumentError` — never returns wrong numbers — when the clip is not
  mono PCM16, or when `fft_size` is smaller than the frame length in samples
  (which would mean truncating audio to fit the transform).
  """
  @spec frames(SoundStudio.t(), opts()) :: [Types.frame()]
  def frames(clip, opts \\ [])

  def frames(%SoundStudio{bits: 16, channels: 1} = clip, opts) do
    fft_size = Keyword.get(opts, :fft_size, @default_fft_size)
    coeff = Keyword.get(opts, :pre_emphasis, @pre_emphasis)
    rate = clip.sample_rate
    frame_len = round(@frame_ms * rate / 1000)

    if fft_size < frame_len do
      raise ArgumentError,
            "fft_size #{fft_size} is smaller than the #{frame_len}-sample analysis frame at " <>
              "#{rate} Hz; a frame cannot be truncated to fit the transform. Pass a larger " <>
              ":fft_size (#{next_power_of_two(frame_len)} or more)."
    end

    cfg = %{
      data: clip.data,
      len: frame_len,
      # Deliberately a float: the sample offset is recomputed as
      # `round(i * hop)` per frame so the rounding error never accumulates.
      hop: @hop_ms * rate / 1000,
      total: div(byte_size(clip.data), 2),
      coeff: coeff,
      window: Tables.hamming(frame_len),
      # One shared immutable tail, reused by every frame rather than rebuilt.
      pad: List.duplicate(0.0, fft_size - frame_len)
    }

    collect(cfg, 0, [])
  end

  def frames(%SoundStudio{} = clip, _opts) do
    raise ArgumentError,
          "frames/2 needs the studio's internal format (mono PCM16); got " <>
            "#{clip.channels} channel(s) at #{clip.bits} bits. Run it through " <>
            "SoundStudio.import_source/1 first."
  end

  @doc """
  The magnitude spectrum of one frame: `n/2 + 1` values, DC through Nyquist.

  An iterative radix-2 Cooley-Tukey FFT — bit-reversal permutation, then
  `log2(n)` butterfly stages. Unscaled, so a DC frame of `n` ones puts `n` in
  bin 0, and magnitudes only, because nothing downstream needs phase.

  Bin `k` is centred on `k * rate / n` Hz. This function is deliberately unaware
  of the sample rate: it is a transform, and only the caller knows what the
  numbers went in as.

  **A frame whose length is not a power of two is zero-padded up to the next
  one, never truncated.** Truncation would silently discard the tail of a frame
  and shift every magnitude, which is the kind of wrong that looks plausible all
  the way to the final splice. Frames from `frames/2` are already padded, so
  this path is for hand-built input.

  Raises `ArgumentError` on an empty frame — there is no spectrum of nothing, and
  returning `[]` would let an empty clip flow silently into the feature stage.
  """
  @spec spectrum(Types.frame()) :: Types.spectrum()
  def spectrum([]) do
    raise ArgumentError, "spectrum/1 needs a non-empty frame; got []"
  end

  def spectrum(frame) when is_list(frame) do
    len = length(frame)
    n = max(2, next_power_of_two(len))

    src = List.to_tuple(frame ++ List.duplicate(0.0, n - len))
    perm = bit_reversal(n)
    twiddles = twiddles(n)

    # The permutation and the real -> complex lift in one pass: input is real, so
    # every imaginary part starts at zero.
    permuted =
      List.to_tuple(for i <- 0..(n - 1), do: {elem(src, elem(perm, i)) * 1.0, 0.0})

    permuted
    |> run_stages(n, 2, twiddles)
    |> magnitudes(div(n, 2))
  end

  # ---------------------------------------------------------------------------
  # Framing
  # ---------------------------------------------------------------------------

  defp collect(cfg, index, acc) do
    start = round(index * cfg.hop)

    if start + cfg.len > cfg.total do
      Enum.reverse(acc)
    else
      collect(cfg, index + 1, [one_frame(cfg, start) | acc])
    end
  end

  # Reads one extra sample *before* the frame so pre-emphasis is continuous with
  # the previous frame. At the very start of the clip there is no earlier sample
  # and the filter's history is zero, which is the standard initialisation.
  defp one_frame(cfg, 0) do
    emit(binary_part(cfg.data, 0, cfg.len * 2), 0.0, cfg.coeff, cfg.window, cfg.pad, [])
  end

  defp one_frame(cfg, start) do
    <<prev::little-signed-16, chunk::binary>> =
      binary_part(cfg.data, (start - 1) * 2, (cfg.len + 1) * 2)

    emit(chunk, prev / @full_scale, cfg.coeff, cfg.window, cfg.pad, [])
  end

  # Decode, pre-emphasise and window in a single walk of the sub-binary, with the
  # window consumed as a list in lockstep rather than indexed — sequential access
  # is the BEAM's strong axis and this is the inner loop of the framing pass.
  defp emit(<<>>, _prev, _coeff, _window, pad, acc), do: Enum.reverse(acc, pad)

  defp emit(<<s::little-signed-16, rest::binary>>, prev, coeff, [w | window], pad, acc) do
    x = s / @full_scale
    emit(rest, x, coeff, window, pad, [(x - coeff * prev) * w | acc])
  end

  # ---------------------------------------------------------------------------
  # FFT
  # ---------------------------------------------------------------------------

  defp run_stages(working, n, m, _twiddles) when m > n, do: working

  defp run_stages(working, n, m, twiddles) do
    working
    |> stage(n, m, twiddles)
    |> run_stages(n, m * 2, twiddles)
  end

  # One decimation-in-time stage. Every block of `m` consecutive values is
  # rewritten as `half` sums followed by `half` differences, so the stage's whole
  # output is built as one cons list in reverse and converted to a tuple once.
  defp stage(working, n, m, twiddles) do
    half = div(m, 2)
    ctx = {working, twiddles, div(n, m)}

    reversed =
      Enum.reduce(0..(n - 1)//m, [], fn block, acc ->
        {tops, bottoms} = butterflies(ctx, block, block + half, block + half, 0, acc, [])
        # Both accumulators are in reverse order, so prepending `bottoms` whole
        # puts the block's second half after its first once the outer list is
        # reversed at the end of the stage.
        bottoms ++ tops
      end)

    reversed |> Enum.reverse() |> List.to_tuple()
  end

  defp butterflies(ctx, low, high, stop, twiddle_index, tops, bottoms) when low < stop do
    {working, twiddles, step} = ctx
    {u_re, u_im} = elem(working, low)
    {v_re, v_im} = elem(working, high)
    {w_re, w_im} = elem(twiddles, twiddle_index)

    t_re = v_re * w_re - v_im * w_im
    t_im = v_re * w_im + v_im * w_re

    butterflies(
      ctx,
      low + 1,
      high + 1,
      stop,
      twiddle_index + step,
      [{u_re + t_re, u_im + t_im} | tops],
      [{u_re - t_re, u_im - t_im} | bottoms]
    )
  end

  defp butterflies(_ctx, _low, _high, _stop, _twiddle_index, tops, bottoms), do: {tops, bottoms}

  defp magnitudes(working, last_bin) do
    for i <- 0..last_bin do
      {re, im} = elem(working, i)
      :math.sqrt(re * re + im * im)
    end
  end

  # ---------------------------------------------------------------------------
  # Tables
  # ---------------------------------------------------------------------------

  defp twiddles(n), do: Map.get_lazy(@twiddles, n, fn -> Tables.twiddles(n) end)
  defp bit_reversal(n), do: Map.get_lazy(@bit_reversal, n, fn -> Tables.bit_reversal(n) end)

  defp next_power_of_two(n) when n >= 1, do: pow2_at_least(1, n)
  defp pow2_at_least(p, n) when p >= n, do: p
  defp pow2_at_least(p, n), do: pow2_at_least(p * 2, n)
end
