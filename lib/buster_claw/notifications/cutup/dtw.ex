defmodule BusterClaw.Notifications.Cutup.Dtw do
  @moduledoc """
  Subsequence dynamic time warping — the matcher of the query-by-example keyword
  spotter (STUDIO_ROADMAP Part III, V.2).

  Give it **one** example of a word (a short template, ~30-80 frames cut out of a
  recording) and a whole recording (a long target, thousands of frames), and it
  reports every span of the target that sounds like the template. There is no
  model, no training data, no download and no network: this is arithmetic over
  feature vectors, and it is deliberately ignorant of where those vectors came
  from. As far as this module is concerned a frame is a point in N-space with a
  distance function — the feature extractor can grow deltas, drop coefficients or
  change filterbanks without a line here changing.

  ## Subsequence, not classic, DTW

  Classic DTW aligns two whole sequences end to end: the path must start at
  `(0, 0)` and finish at `(m-1, n-1)`. That answers *"how similar are these two
  clips"* and is what `distance/3` does.

  It is the wrong question for spotting. A word occurs 4.2 seconds into a
  two-minute voicemail, and forcing the alignment to consume the whole recording
  makes every match look terrible. **Subsequence DTW frees both ends in the
  target**: the first row of the cost matrix is initialised to the *local*
  distance rather than to a running sum, so a path may begin at any target frame
  for free, and matches are read off the last row — one candidate per target
  frame, each being "the best-scoring alignment of the whole template that
  finishes here". The template is still consumed whole; only the target is free.

  ## Length normalisation, which is the entire point

  `distance` on a `t:BusterClaw.Notifications.Cutup.Types.match/0` is the
  accumulated cost **divided by the length of the warping path**. Without that
  division a 60-frame template accumulates roughly three times the cost of a
  20-frame one purely for being longer, so no single `:threshold` can hold across
  words of different lengths — and a keyword spotter whose threshold has to be
  re-tuned per word is not a keyword spotter, it is a per-word science project.
  That trap is the usual reason naive DTW spotters are useless in practice.

  ### Carrying `{cost, length, start}` per cell, rather than backtracking

  Dividing by path length means knowing the path length, and there are two ways
  to know it: reconstruct the path by backtracking from the winning cell, or
  carry the length forward in the cell. **This carries it.** Each cell is a flat
  three-tuple `{cost, length, start_frame}`:

  - it is O(1) extra work and two extra words of memory per cell, against a
    backtrack that needs the *whole* matrix retained — 1.8M cells for a 60-frame
    template over a 30,000-frame recording, which is precisely the allocation the
    column-at-a-time loop below exists to avoid;
  - `start_frame` rides along for free by the same mechanism, so the match's left
    edge is known without a backtrack either.

  **The recurrence still minimises accumulated cost, not the ratio.** This is the
  part that is easy to get wrong. Length normalisation is applied *once, at the
  end*; it is not folded into the `min`. Minimising `(cost + d) / (length + w)`
  cell by cell would be a greedy heuristic with no optimal substructure — the
  argmin of a ratio does not decompose, so the result is optimal for neither
  objective and the score stops meaning anything. So: decide on cost, carry the
  length, divide last.

  ## Step pattern: the symmetric one, diagonal weighted 2

  The three standard moves — diagonal (match), vertical (the template advances
  while the target does not), horizontal (the target advances while the template
  does not) — with weights **2 for the diagonal and 1 for each axis move**, and
  the free-start cell entered with weight 2.

  With all weights 1 the diagonal is a discount: it advances both sequences for
  the price of one local distance, so a straight path scores structurally lower
  than a warped one and the normalised distance quietly measures *how much
  warping happened* as much as it measures acoustic similarity. Weighting the
  diagonal 2 removes that bias and buys a clean interpretation:

  > **the normalised distance is the weighted mean local frame distance along the
  > best path**, in whatever units the feature vectors are in.

  It also buys two properties worth knowing:

  - for full DTW the path weight is **exactly `m + n`**, independent of the path
    taken, so `distance/3` is `cost / (m + n)`; and
  - `distance/3` is **symmetric**: `distance(a, b) == distance(b, a)`, because
    transposing the matrix swaps the two weight-1 moves for each other.

  Ties prefer the diagonal, then the vertical, then the horizontal, which keeps
  paths from wandering and makes the whole thing deterministic.

  ## One column at a time

  A 60-frame template against a 30-second recording is ~1.8M cells. Nothing
  materialises them. The matrix is walked one *target* column at a time, keeping
  only the previous column, so memory is O(template) — a 60-element list —
  regardless of how long the recording is.

  Within a column the previous column is consumed **in lockstep** rather than
  indexed: filling row `i` needs exactly `prev[i-1]` (diagonal), `prev[i]`
  (horizontal) and the just-computed `cur[i-1]` (vertical), and walking two lists
  head-first hands over the first two while an accumulator holds the third. That
  is O(1) per cell with no tuple conversion and no `Enum.at/2` — the latter would
  make each column O(m²) and the search unusable.

  Cost is O(m·n) frame distances, which is irreducible for exact DTW; no
  Sakoe-Chiba band is applied, because banding a *subsequence* search constrains
  exactly the warping the search exists to find.

  ### Measured, so the "effectively instant" in the roadmap is a number

  On the development machine (M-series, OTP 28), 13-dimensional features,
  Euclidean, single process:

  | template | target | cells | wall | target frames/s |
  |---|---|---|---|---|
  | 30 | 30,000 | 0.9M | 0.56 s | 53,800 |
  | 60 | 30,000 | 1.8M | 1.08 s | 27,700 |
  | 80 | 30,000 | 2.4M | 1.49 s | 20,200 |

  That is **~1.6M cells/second and flat across template lengths**, which is the
  observable proof that the per-cell work is O(1) — an `Enum.at/2` column would
  bend that column downward as `m` grew.

  Read off it: a **30-second recording is 3,000 frames, so a 60-frame template
  searches it in ~0.11 s**, and the roadmap's whole 295-second corpus in about a
  second. Ten five-minute recordings — 50 minutes of audio — take 2.1 s through
  `Task.async_stream/3`. Search is not the expensive half of this pipeline; the
  FFT that produces its input is, and search never needs to be cached.

  ## Honest limits

  - **The threshold has no natural scale and must be tuned against a real
    corpus.** It is a mean local distance in feature units, so it moves with the
    feature extractor, the coefficient count, whether liftering was applied, and
    the recording chain. Any number written here would be a lie; the roadmap's
    warning that tuning it may cost as long as writing the matcher stands. There
    is, however, a way to find it that is not guesswork — see below.
  - **Speaker- and channel-dependent by construction.** The same word from a
    different caller usually will not match. For assembling audio that has to
    sound like one voice that is the desired behaviour, not a defect.
  - **A reported span is the tightest one that scores best, so a slowly-spoken
    instance is trimmed at both edges.** When a word is stretched relative to the
    template, the reported onset lands on the *last* repeated frame (row 0 is a
    free start and nothing else — see above) and the offset on the *first*, so
    the span is short by roughly `(stretch factor - 1)` frames at each end, or
    10 ms per factor. `Assemble` pads 30 ms outward before it cuts, which covers
    this; a caller that does its own cutting should know it is there.
  - **The non-overlap pass is greedy, not globally optimal.** Candidates are
    taken best-first and later ones that conflict are dropped. A pathological
    arrangement where two mediocre non-conflicting matches beat one good one is
    possible; it has never been the interesting case for this workload.
  - **`:cmn` is off by default and may not be yours to turn on.** Cepstral mean
    normalisation (subtracting each sequence's own mean vector) is what stops a
    channel difference between two phone calls dominating the distance, and the
    roadmap asks for it at this stage — but it is a feature-domain operation that
    may equally live in the MFCC stage. Enabling it here on features that already
    had it applied subtracts a near-zero mean twice, which is harmless but
    pointless; enabling it on features that did not is the intended use. Know
    which you have.
  - **Frames are the clock.** `start_ms`/`end_ms` are derived from the 10 ms hop
    pinned in `BusterClaw.Notifications.Cutup.Types`. A template extracted at one
    hop and a recording analysed at another cannot be compared at all, and this
    module cannot detect that mistake.

  ## Finding the threshold without guessing

  The scale is unknown but it is *measurable*, and the measurement needs no
  labels:

  1. Run `search/3` with no `:threshold` and `limit: 1` against a recording you
     know does **not** contain the word. The score you get back is the
     **false-alarm floor** — the best that coincidence can do in that feature
     space and that recording chain.
  2. Do the same against a recording you know does contain it. That is the
     **hit ceiling**.
  3. Put the threshold between them, nearer the floor than the middle, because
     a missed word costs one search and a false one costs a bad splice.

  On the synthetic 13-dimensional features these tests are built from, the floor
  sits at **~2.2** (and barely moves between a 1,000-frame and a 30,000-frame
  target, so it does not have to be re-measured per recording length), a
  perturbed true instance scores **0.1–0.8**, and matching breaks down where the
  two meet. That put the usable band around **0.2–0.9**, roughly a third of the
  floor. **Those numbers are for synthetic uniform noise and will not transfer**
  — real cepstra are correlated frame to frame and 8 kHz telephony is its own
  problem — but the *shape* transfers, and step 1 is a one-line experiment.

  What does transfer, because it is the normalisation and not the data: at a
  fixed perturbation the score is length-independent to about **1% across a 4×
  range of template lengths** (20 to 80 frames). That is the property one
  threshold across many words depends on, and it is asserted in the tests.
  """

  alias BusterClaw.Notifications.Cutup.Types

  # The analysis clock, pinned in `Types` and restated here rather than imported
  # from the framing stage: the matcher must not depend on the front end, and a
  # frame index is only convertible to a time by these two numbers.
  @hop_ms 10.0

  @default_limit 10

  @typedoc """
  Why a pair of sequences could not be matched. `search/3` swallows these and
  returns `[]`; call `validate/3` when you need to know which one it was.

  - `:empty_template` / `:empty_target` — one side had no frames. For
    `distance/3` the first argument plays the template role.
  - `:template_longer_than_target` — a template cannot be *found inside*
    something shorter than itself. `search/3` only. (`distance/3` is happy either
    way round.)
  - `:ragged_features` — the feature vectors are not all the same dimension.
    Almost always two sequences produced by different extractor settings, which
    is a mistake worth naming rather than silently truncating.
  - `:not_a_sequence` — not a list of non-empty lists of numbers.
  """
  @type reason ::
          :empty_template
          | :empty_target
          | :template_longer_than_target
          | :ragged_features
          | :not_a_sequence

  @typedoc """
  How to measure the distance between two single frames. Euclidean is the
  default and the right one for cepstral features; the others are here because
  making it swappable cost nothing, and a 2-arity function is accepted so a
  caller can supply its own without this module knowing about it.
  """
  @type metric ::
          :euclidean
          | :manhattan
          | :cosine
          | (Types.features(), Types.features() -> number())

  @typedoc """
  - `:threshold` — keep only matches whose **normalised** distance is at or below
    this. Defaults to `:infinity`, i.e. no filtering, because there is no
    defensible default in feature units (see the moduledoc).
  - `:limit` — how many matches to return, best first. Defaults to
    `#{@default_limit}`; pass `:infinity` for all of them. Truncation happens
    after ranking, so a limit never costs you the best hit.
  - `:min_gap_frames` — how far apart two reported matches must *start*, so one
    spoken word does not report five overlapping near-identical hits. Defaults to
    the template length, which is the shortest gap at which two genuine
    back-to-back instances can occur. Overlapping spans are rejected regardless.
  - `:metric` — see `t:metric/0`.
  - `:cmn` — apply cepstral mean normalisation to both sequences first. Off by
    default; read the moduledoc before turning it on.
  """
  @type opts :: [
          threshold: number() | :infinity,
          limit: pos_integer() | :infinity,
          min_gap_frames: non_neg_integer(),
          metric: metric(),
          cmn: boolean()
        ]

  # A cell of the cost matrix: accumulated cost, accumulated path weight, and the
  # target frame the path started on.
  @typep cell :: {float(), pos_integer(), non_neg_integer()}

  @doc """
  Find every span of `target` that matches `template`, best first.

  Returns a list of `t:BusterClaw.Notifications.Cutup.Types.match/0` — never
  raises, and returns `[]` for any input `validate/3` rejects.

  Matches are non-overlapping and at least `:min_gap_frames` apart, so a single
  spoken word reports once rather than once per frame of its neighbourhood.

  ## Examples

      iex> alias BusterClaw.Notifications.Cutup.Dtw
      iex> template = [[0.0], [1.0], [0.0]]
      iex> target = [[5.0], [5.0], [0.0], [1.0], [0.0], [5.0]]
      iex> [match] = Dtw.search(template, target, threshold: 1.0e-9)
      iex> {match.start_frame, match.end_frame, match.distance}
      {2, 4, 0.0}
  """
  @spec search(Types.feature_seq(), Types.feature_seq(), opts()) :: [Types.match()]
  def search(template, target, opts \\ []) do
    case validate(template, target, :search) do
      :ok -> do_search(template, target, opts)
      {:error, _reason} -> []
    end
  end

  @doc """
  Full (classic) DTW between two whole sequences, length-normalised.

  Both sequences are consumed end to end, so this answers *"how similar are these
  two clips"* rather than *"where inside this recording"*. Useful on its own for
  ranking candidate takes of the same word against each other.

  Returns a float, or `{:error, t:reason/0}` for degenerate input — it never
  raises. Because of the symmetric step weights the returned value is
  `cost / (length(a) + length(b))`, and `distance(a, b) == distance(b, a)`.

  ## Examples

      iex> alias BusterClaw.Notifications.Cutup.Dtw
      iex> seq = [[0.0, 1.0], [2.0, 3.0], [4.0, 5.0]]
      iex> Dtw.distance(seq, seq)
      0.0

      iex> alias BusterClaw.Notifications.Cutup.Dtw
      iex> Dtw.distance([[0.0]], [])
      {:error, :empty_target}
  """
  @spec distance(Types.feature_seq(), Types.feature_seq(), opts()) ::
          float() | {:error, reason()}
  def distance(seq_a, seq_b, opts \\ []) do
    case validate(seq_a, seq_b, :distance) do
      :ok ->
        {a, b} = maybe_cmn(seq_a, seq_b, opts)
        [{dist, _start, _end} | _] = fold_columns(a, b, :full, metric_fun(opts))
        dist

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Check a pair of sequences without matching them.

  `search/3` returns `[]` rather than an error tuple because its contract is a
  list of matches; this is how a caller finds out *why* the list was empty.
  `mode` is `:search` (the default, where a template longer than the target is
  refused) or `:distance` (where it is fine).
  """
  @spec validate(Types.feature_seq(), Types.feature_seq(), :search | :distance) ::
          :ok | {:error, reason()}
  def validate(template, target, mode \\ :search) do
    with :ok <- check_sequence(template, :empty_template),
         :ok <- check_sequence(target, :empty_target),
         :ok <- check_dimensions(template, target) do
      check_lengths(template, target, mode)
    end
  end

  # ── Validation ─────────────────────────────────────────────────────────────

  defp check_sequence([], empty_reason), do: {:error, empty_reason}

  defp check_sequence(seq, _empty_reason) when is_list(seq) do
    if Enum.all?(seq, &vector?/1), do: :ok, else: {:error, :not_a_sequence}
  end

  defp check_sequence(_other, _empty_reason), do: {:error, :not_a_sequence}

  defp vector?([_ | _] = vec), do: Enum.all?(vec, &is_number/1)
  defp vector?(_other), do: false

  defp check_dimensions([first | _] = template, target) do
    dim = length(first)

    if uniform?(template, dim) and uniform?(target, dim) do
      :ok
    else
      {:error, :ragged_features}
    end
  end

  defp uniform?(seq, dim), do: Enum.all?(seq, &(length(&1) == dim))

  defp check_lengths(template, target, :search) do
    if length(template) > length(target) do
      {:error, :template_longer_than_target}
    else
      :ok
    end
  end

  defp check_lengths(_template, _target, _mode), do: :ok

  # ── Search ─────────────────────────────────────────────────────────────────

  defp do_search(template, target, opts) do
    {tpl, tgt} = maybe_cmn(template, target, opts)
    threshold = Keyword.get(opts, :threshold, :infinity)
    limit = Keyword.get(opts, :limit, @default_limit)
    min_gap = Keyword.get(opts, :min_gap_frames, length(template))

    tpl
    |> fold_columns(tgt, :subsequence, metric_fun(opts))
    |> Enum.filter(fn {dist, _start, _end} -> below?(dist, threshold) end)
    |> Enum.sort()
    |> select(min_gap, limit, 0, [])
    |> Enum.map(&to_match/1)
  end

  defp below?(_dist, :infinity), do: true
  defp below?(dist, threshold), do: dist <= threshold

  # Greedy best-first: take the best candidate, drop everything that conflicts
  # with an already-taken one, repeat. `taken` is bounded by `limit`, so the
  # pairwise conflict check stays cheap in the configured case.
  defp select([], _gap, _limit, _count, taken), do: Enum.reverse(taken)

  defp select(_rest, _gap, limit, count, taken) when is_integer(limit) and count >= limit do
    Enum.reverse(taken)
  end

  defp select([candidate | rest], gap, limit, count, taken) do
    if conflicts?(candidate, taken, gap) do
      select(rest, gap, limit, count, taken)
    else
      select(rest, gap, limit, count + 1, [candidate | taken])
    end
  end

  defp conflicts?({_dist, start, stop}, taken, gap) do
    Enum.any?(taken, fn {_d, other_start, other_stop} ->
      abs(start - other_start) < gap or (start <= other_stop and other_start <= stop)
    end)
  end

  defp to_match({dist, start, stop}) do
    %{
      start_frame: start,
      end_frame: stop,
      start_ms: start * @hop_ms,
      end_ms: (stop + 1) * @hop_ms,
      distance: dist
    }
  end

  # ── The matrix, one target column at a time ────────────────────────────────

  # Returns `{normalised_distance, start_frame, end_frame}` for the last row of
  # every target column, most recent column first. For `:full` mode only the head
  # is meaningful; for `:subsequence` every element is a candidate match.
  @spec fold_columns(Types.feature_seq(), Types.feature_seq(), :subsequence | :full, fun()) ::
          [{float(), non_neg_integer(), non_neg_integer()}]
  defp fold_columns(template, target, mode, metric) do
    {_final_column, candidates} =
      target
      |> Enum.with_index()
      |> Enum.reduce({nil, []}, fn {frame, j}, {prev_column, acc} ->
        distances = Enum.map(template, &metric.(&1, frame))
        {column, {cost, weight, start}} = column(distances, prev_column, j, mode)
        {column, [{cost / weight, start, j} | acc]}
      end)

    candidates
  end

  # The very first target column. Row 0 is a free start on frame 0; every row
  # below it can only be reached by a vertical move, which is the whole template
  # compressed onto one target frame.
  defp column(distances, nil, _j, _mode), do: first_column(distances)
  defp column(distances, prev_column, j, mode), do: next_column(distances, prev_column, j, mode)

  defp first_column([d | rest]) do
    head = {2.0 * d, 2, 0}
    walk_down(rest, head, [head])
  end

  defp walk_down([], last, acc), do: {:lists.reverse(acc), last}

  defp walk_down([d | rest], {cost, weight, start}, acc) do
    cell = {cost + d, weight + 1, start}
    walk_down(rest, cell, [cell | acc])
  end

  defp next_column([d | rest], [p_here | p_rest], j, mode) do
    head = row_zero(d, p_here, j, mode)
    walk_rows(rest, p_rest, p_here, head, [head])
  end

  # `:subsequence` initialises row 0 to the bare local distance: the path may
  # begin at this target frame for free, which is the one line that separates
  # subsequence DTW from the classic kind. `:full` accumulates horizontally
  # instead, forcing the alignment to consume the target from frame 0.
  defp row_zero(d, _p_here, j, :subsequence), do: {2.0 * d, 2, j}
  defp row_zero(d, {cost, weight, start}, _j, :full), do: {cost + d, weight + 1, start}

  defp walk_rows([], _prev, _diag, last, acc), do: {:lists.reverse(acc), last}

  defp walk_rows([d | rest], [p_here | p_rest], diag, above, acc) do
    cell = best(d, diag, above, p_here)
    walk_rows(rest, p_rest, p_here, cell, [cell | acc])
  end

  # The three moves. Decided on accumulated cost — never on the ratio — with the
  # diagonal weighted 2 so it is not a discount relative to two axis moves. Ties
  # go diagonal, then vertical, then horizontal, which is both the least-warping
  # choice and what makes the whole search deterministic.
  @spec best(float(), cell(), cell(), cell()) :: cell()
  defp best(
         d,
         {d_cost, d_weight, d_start},
         {v_cost, v_weight, v_start},
         {h_cost, h_weight, h_start}
       ) do
    diagonal = d_cost + 2.0 * d
    vertical = v_cost + d
    horizontal = h_cost + d

    cond do
      diagonal <= vertical and diagonal <= horizontal -> {diagonal, d_weight + 2, d_start}
      vertical <= horizontal -> {vertical, v_weight + 1, v_start}
      true -> {horizontal, h_weight + 1, h_start}
    end
  end

  # ── Frame metrics ──────────────────────────────────────────────────────────

  defp metric_fun(opts) do
    case Keyword.get(opts, :metric, :euclidean) do
      :euclidean -> &euclidean/2
      :manhattan -> &manhattan/2
      :cosine -> &cosine/2
      fun when is_function(fun, 2) -> fun
      _unknown -> &euclidean/2
    end
  end

  defp euclidean(a, b), do: :math.sqrt(sum_squares(a, b, 0.0))

  defp sum_squares([], [], acc), do: acc

  defp sum_squares([a | as], [b | bs], acc) do
    d = a - b
    sum_squares(as, bs, acc + d * d)
  end

  defp manhattan(a, b), do: sum_abs(a, b, 0.0)

  defp sum_abs([], [], acc), do: acc
  defp sum_abs([a | as], [b | bs], acc), do: sum_abs(as, bs, acc + abs(a - b))

  # 1 - cosine similarity, floored at 0.0 so it can never go negative through
  # float error. A zero vector has no direction, so it is maximally dissimilar.
  defp cosine(a, b) do
    {dot, norm_a, norm_b} = cosine_parts(a, b, 0.0, 0.0, 0.0)

    if norm_a == 0.0 or norm_b == 0.0 do
      1.0
    else
      max(1.0 - dot / (:math.sqrt(norm_a) * :math.sqrt(norm_b)), 0.0)
    end
  end

  defp cosine_parts([], [], dot, norm_a, norm_b), do: {dot, norm_a, norm_b}

  defp cosine_parts([a | as], [b | bs], dot, norm_a, norm_b) do
    cosine_parts(as, bs, dot + a * b, norm_a + a * a, norm_b + b * b)
  end

  # ── Cepstral mean normalisation ────────────────────────────────────────────

  defp maybe_cmn(a, b, opts) do
    if Keyword.get(opts, :cmn, false), do: {cmn(a), cmn(b)}, else: {a, b}
  end

  defp cmn([first | _] = seq) do
    count = length(seq)
    zeros = List.duplicate(0.0, length(first))
    sums = Enum.reduce(seq, zeros, fn vec, acc -> Enum.zip_with(vec, acc, &(&1 + &2)) end)
    means = Enum.map(sums, &(&1 / count))

    Enum.map(seq, fn vec -> Enum.zip_with(vec, means, &(&1 - &2)) end)
  end
end
