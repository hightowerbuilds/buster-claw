defmodule BusterClaw.Notifications.Cutup.Select do
  @moduledoc """
  Unit selection — deciding **which take of each word** an assembled sentence
  uses (STUDIO_ROADMAP Part IV).

  `Assemble` is handed an ordered list of cuts and splices them. Nothing, until
  this module, chose those cuts. The first real paragraph picked by median
  duration, which is very nearly arbitrary, and the verdict was "garbled". With
  9 takes of *morning* and 35 of *to* in the corpus, **the choice of take is most
  of the quality**, and it is the one part of the pipeline where a better answer
  costs no new audio and no new permission.

  The technique is the classical one: a sentence is a **lattice** — one slot per
  target word, N candidate takes per slot — every path through it is a possible
  sentence, and the cheapest path wins. Two costs shape it:

  - a **target cost**, *is this take good for this slot*, ignoring neighbours;
  - a **join cost**, *does this take splice cleanly onto the next one*.

  This is concatenative-TTS unit selection, and our data was already in its
  shape before anyone noticed.

  ## Nothing is loaded here, and that is deliberate

  Feature sequences arrive through `opts[:features]` and boundary quiet arrives
  through `opts[:boundary]`. This module opens no files, reads no cache and
  touches no audio: it is arithmetic over injected data, so every decision it
  makes is reproducible from a literal in a test. `Cutup.Features` owns the IO
  and the caching; measuring boundary energy needs the per-frame energy profile,
  which is IO by another name, so it is a caller-supplied number here.

  The cost of that purity is honest: **a caller that injects nothing gets a
  selection made on confidence and duration alone.** `explain/2` reports how many
  terms had to be imputed, so "the acoustics were not available" is a number
  rather than a silence.

  ## Normalisation, which is what makes the weights mean anything

  The four target terms live on wildly different scales — a confidence is 0–1, a
  duration ratio is unbounded, a DTW distance in cepstral units runs 0 to ~13
  and moves with the feature extractor. Weight those raw and the term with the
  widest spread silently becomes the only term that matters; the other weights
  are decorative and nobody finds out, because there is no error and no symptom
  except choices that are quietly poor. That failure mode is the same family as
  the one `Dtw`'s length normalisation exists to kill.

  So **every term is min–max normalised to 0.0–1.0 before it is weighted**, over
  one pooled population:

  > **the population is every candidate in the whole lattice** — all slots
  > together, not each slot separately — and for the join terms, every candidate
  > *pair* the search could evaluate.

  Pooling across slots rather than within them is the choice worth defending. A
  within-slot normalisation would map the best candidate of a uniformly terrible
  slot to 0.0, erasing the fact that the slot is terrible; pooled, a bad slot
  stays visibly expensive and `explain/2` can show it. It also survives the
  one-candidate slot, where a within-slot min and max are the same number.

  Two consequences, stated rather than hidden:

  - **min–max makes every term equally loud regardless of how much it actually
    varies.** If all nine takes of *morning* have confidences within 0.01 of each
    other, that 0.01 is stretched across the full 0–1 range and can then tip a
    decision on what is essentially noise. The guard is the degenerate case: a
    term with **zero spread contributes exactly 0.0 to every candidate**, so a
    constant term is silent rather than arbitrary.
  - **it is relative, not absolute.** A cost of 0.0 means *best in this lattice*,
    never *good* — see "No path through a bad candidate set is good" below — and
    **two plans from two different lattices cannot be ranked against each
    other.** Dropping a candidate re-scales every term for the survivors, so a
    caller tempted to price an alternative sentence by forcing it through
    `explain/2` will get a number measured against a different population.

  A term that could not be computed for a candidate — no features for its source,
  no boundary value supplied — is **imputed the median of the observable
  population**, so a missing measurement is neither a reward nor a punishment,
  and the count is reported.

  ## Target cost

  All four are already computable from what exists.

  - **`confidence`** — `1.0 - word.confidence`. `Types` is explicit that
    recognisers disagree about what a confidence means and it should be treated
    as a ranking signal; min–max normalisation is exactly that treatment.
  - **`duration`** — how far the take's duration sits from a syllable
    expectation, `Align.syllables/1 * syllable_ms` (default
    `#{trunc(200.0)}` ms, conversational English at about five syllables a
    second). The raw penalty is `1 - exp(-0.5 * (ln(actual/expected) / ln 2)²)`,
    **the same Gaussian in the log of the ratio that `Align` scores with**,
    because half and double are equally wrong and a linear error is not. A word
    crushed to 40 ms or stretched over 2 s lands near 1.0.
  - **`boundary`** — how quiet the audio is at the cut edges: a cut through a
    vowel is measurably worse than a cut at a closure. Supplied by the caller
    (`opts[:boundary]`) in any units, higher meaning worse; it is min–max
    normalised, so the scale does not matter and it is **not clamped**.
  - **`typicality`** — the mean `Dtw.distance/3` from this take to other takes of
    the same word anywhere in the lattice. A take far from its eight siblings is
    probably mis-aligned. This is a similarity measure and not a quality one:
    it finds the *odd* take, which is usually the broken one and occasionally the
    only interesting one.

  ## Join cost, and the natural-run rule

  - **`spectral`** — cepstral distance across the seam, the standard
    unit-selection join cost: the mean feature vector of A's last `:seam_frames`
    against the mean of B's first `:seam_frames`, Euclidean **over coefficients 1
    and up**. Means rather than frame-to-frame pairs because pairing A's
    *k*-from-last against B's first compares points 2k frames apart in time,
    which is not a seam.
  - **`level`** — the absolute difference in **coefficient 0**, which for MFCCs
    is the frame's log energy. It rides alongside the spectral term because
    `SoundStudio.normalize/2` equalises *peaks*, not loudness, so a level jump at
    a seam is plainly audible even when the spectrum matches. Excluding c0 from
    the spectral term is what stops the two terms measuring the same thing twice.

  And the rule that earns this cost its keep:

  > **Two candidates that were adjacent in the same source recording join at
  > exactly zero.** They were originally spoken together; there is no seam to
  > hear, and co-articulation across it is real speech rather than a splice.

  That is applied *after* normalisation — the pair still contributes its honest
  raw distance to the population, so one natural run cannot compress the scale
  everything else is judged on — and it holds even when no features were
  injected at all. Its practical effect is that the search prefers to keep runs
  of real speech intact and only pays for a seam where it has to, which is the
  single most valuable thing a join cost can do for this material.

  Adjacency is: **same source**, and `|b.frame0 - a.frame1|` within
  `:adjacent_tolerance_frames` (default 2, i.e. 20 ms at the pinned hop). The
  asymmetry is what makes it an *order* test rather than a proximity one — B has
  to start where A ended, so a take that merely lives nearby in the same
  recording, or the same pair the other way round, is an ordinary splice. The
  tolerance is slack for a boundary that was rounded rather than measured; it is
  nowhere near a syllable.

  ## The search

  Viterbi over the lattice: the cheapest total of every target cost on the path
  plus every join cost between its consecutive members. Only the previous column
  is kept, as `Dtw` does.

  Where this departs from `Dtw` is that **the winning path is carried in the
  cell rather than backtracked** — which `Dtw` also does for its start frame, but
  here it is the whole path. `Dtw` could not afford that: 1.8M cells is exactly
  the allocation its column loop exists to avoid. This lattice is a sentence —
  ten slots of thirty candidates is three hundred cells — so carrying a list of
  at most ten integers per cell costs nothing and removes a backtrack that would
  otherwise need every column retained.

  **Tie-break, because determinism has to be a decision and not an accident:**
  equal-cost paths resolve toward **the candidate listed earlier by the caller**,
  worked out from the last slot backwards (the final column is scanned in order
  and improvements must be strict, and so is each predecessor scan). A caller
  who wants a particular take to win a genuine tie should put it first in its
  slot. Identical input always produces an identical answer; no term is derived
  from a map's iteration order.

  ## What this will not do

  - **No path through a bad candidate set is good.** The search cannot invent
    audio. With one or two takes in a slot it has nothing to decide, and the
    normalisation is relative, so it will still report a cost of 0.0 for the best
    of two bad options. **The corpus is the constraint here, not the algorithm**
    — which is the argument for building this early (STUDIO_ROADMAP Part V):
    it improves on its own as recordings accumulate, without a line changing.
    `explain/2` returns `slots` and `candidates` so a caller can say out loud
    that the search had no room.
  - **The weights are hand-set and they are guesses.** All four target terms
    default to 1.0 because there is no evidence to rank them and equal is the
    only defensible prior; the join defaults are `spectral: 2.0, level: 1.0`
    because a spectral discontinuity is the standard dominant seam artefact and
    level is partly compensated by `normalize/2` upstream. The two totals are
    deliberately comparable in magnitude (target 0–4, join 0–3) so neither can
    override the other outright. **Fitting them needs pairwise labels from an
    operator's ear, and those labels do not exist yet** — that is Part VI, and
    until it runs these numbers are a starting point, not a result. They are
    options for exactly that reason.
  - **It knows nothing about phonetics.** Adjacency is measured in frames, not in
    phones; the join cost cannot tell that a plosive onset was clipped, only that
    the cepstra either side of the seam differ. `Assemble`'s outward padding is
    still what makes a word arrive with its consonant attached.
  - **`level` is c0, which is frame log-energy, not perceived loudness.** It is a
    continuity term and a good one; it is not a loudness model.
  - **Cost is `O(Σ nᵢ·nᵢ₊₁)` join evaluations plus one DTW per candidate–sibling
    pair.** The DTW is the expensive half, which is why `:max_siblings` caps the
    sibling sample at #{12} (evenly spaced, deterministic) — 35 takes of *to*
    would otherwise be 1,225 DTW runs for one slot.
  """

  alias BusterClaw.Notifications.Cutup.Align
  alias BusterClaw.Notifications.Cutup.Dtw
  alias BusterClaw.Notifications.Cutup.Types

  # Conversational English runs roughly five syllables a second. Restated from
  # `Align` rather than imported: the duration expectation is this module's own
  # judgement, and a caller may hold a different one through `:syllable_ms`.
  @syllable_ms 200.0

  # A factor of two in either direction is one standard deviation of "wrong",
  # which is the tolerance `Align` scores durations with.
  @log_tolerance :math.log(2.0)

  # How many frames either side of a seam are averaged into the comparison.
  @seam_frames 3

  # How far apart two frame indices may be and still count as contiguous speech.
  # Two frames is 20 ms at the pinned hop — slack for a boundary that was rounded
  # rather than measured, and nowhere near a syllable.
  @adjacent_tolerance_frames 2

  # The DTW-per-sibling cap. See the moduledoc's cost note.
  @max_siblings 12

  @default_weights %{
    confidence: 1.0,
    duration: 1.0,
    boundary: 1.0,
    typicality: 1.0,
    spectral: 2.0,
    level: 1.0
  }

  @typedoc """
  Why a selection could not be made. Every one of these is a caller mistake that
  is worth naming rather than guessing past — nothing here ever raises.

  - `:no_slots` — `slots` was not a non-empty list of lists.
  - `:empty_slot` — some slot had no candidates, so no path exists. The first
    such slot is what triggers it.
  - `:bad_candidate` — a candidate did not match `t:Types.candidate/0`: a
    missing key, a non-binary source, a `frame1` before its `frame0`.
  - `:bad_features` — `opts[:features]` was neither a map nor a 1-arity
    function, or one returned something that is not a list of numeric vectors.
  - `:ragged_features` — the feature vectors are not all the same dimension,
    within a source or between two of them. Almost always two sequences produced
    by different extractor settings, and comparing them is meaningless rather
    than merely inaccurate — the same refusal `Dtw.validate/3` makes.
  - `:bad_weights` — a weight was not a non-negative number. A negative weight
    turns a cost into a reward, which is never what anyone meant.
  """
  @type reason ::
          :no_slots
          | :empty_slot
          | :bad_candidate
          | :bad_features
          | :ragged_features
          | :bad_weights

  @typedoc """
  How to choose.

  - `:features` — `%{source => t:Types.feature_seq/0}` or a 1-arity function
    from a source basename to one (or `nil`). **Injected, never loaded here.**
    Absent features cost the acoustic terms, not the run.
  - `:boundary` — how loud the audio is at a candidate's cut edges, higher being
    worse: a map keyed `{source, frame0}` or a 1-arity function of the
    candidate. Any units; it is normalised.
  - `:weights` — a map or keyword overriding any of
    `#{inspect(Map.keys(@default_weights))}`. Defaults in the moduledoc.
  - `:syllable_ms` — the duration expectation for one syllable. Default
    `#{trunc(@syllable_ms)}`; lower it for a fast speaker.
  - `:seam_frames` — frames averaged either side of a seam. Default
    `#{@seam_frames}`.
  - `:adjacent_tolerance_frames` — the natural-run slack. Default
    `#{@adjacent_tolerance_frames}`.
  - `:max_siblings` — DTW comparisons per candidate for typicality. Default
    `#{@max_siblings}`.
  - `:normalize` — `:minmax` (default) or `:none`. **`:none` is a diagnostic**,
    there to make the moduledoc's claim checkable: it feeds raw terms straight to
    the weights, which is the failure this module exists to avoid.
  """
  @type opts :: [
          features: %{String.t() => Types.feature_seq()} | (String.t() -> term()),
          boundary:
            %{{String.t(), non_neg_integer()} => number()} | (Types.candidate() -> term()),
          weights: %{atom() => number()} | keyword(),
          syllable_ms: number(),
          seam_frames: pos_integer(),
          adjacent_tolerance_frames: non_neg_integer(),
          max_siblings: pos_integer(),
          normalize: :minmax | :none
        ]

  @typedoc """
  The chosen path and its full cost breakdown — what `explain/2` adds over
  `best/2`, so a caller can answer *why did it pick that one*.

  `targets` is one entry per slot and `joins` one per seam, so
  `length(joins) == length(targets) - 1`. `imputed` counts the terms that had to
  be filled from the population median because the data to compute them was not
  injected; a large number there means the selection was made on less than it
  looks like. `slots` and `candidates` are the honesty pair: `candidates ==
  slots` means every slot had exactly one take and the search decided nothing.
  """
  @type plan :: %{
          cuts: [Types.cut()],
          path: [Types.candidate()],
          targets: [Types.target_cost()],
          joins: [Types.join_cost()],
          target_total: float(),
          join_total: float(),
          total: float(),
          weights: %{atom() => float()},
          imputed: %{
            boundary: non_neg_integer(),
            typicality: non_neg_integer(),
            join: non_neg_integer()
          },
          slots: non_neg_integer(),
          candidates: non_neg_integer()
        }

  @doc """
  Choose the cheapest take for every slot, in sentence order.

  `slots` is one list of candidates per target word. The result feeds
  `Cutup.Assemble.build/2` directly.

  ## Examples

      iex> alias BusterClaw.Notifications.Cutup.Select
      iex> take = %{
      ...>   source: "voicemail.wav",
      ...>   word: %{word: "morning", text: "Morning", start_ms: 100.0, end_ms: 480.0, confidence: 0.9},
      ...>   frame0: 10,
      ...>   frame1: 48
      ...> }
      iex> Select.best([[take]])
      {:ok, [%{source: "voicemail.wav", start_ms: 100.0, end_ms: 480.0}]}

      iex> alias BusterClaw.Notifications.Cutup.Select
      iex> Select.best([])
      {:error, :no_slots}

      iex> alias BusterClaw.Notifications.Cutup.Select
      iex> Select.best([[]])
      {:error, :empty_slot}
  """
  @spec best([[Types.candidate()]], opts()) :: {:ok, [Types.cut()]} | {:error, reason()}
  def best(slots, opts \\ []) do
    case explain(slots, opts) do
      {:ok, plan} -> {:ok, plan.cuts}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  As `best/2`, but returning the whole `t:plan/0` — the cuts, the candidates
  behind them, every term of every cost, and how much had to be imputed.

  This is the introspection path. `best/2` is this with one field taken.
  """
  @spec explain([[Types.candidate()]], opts()) :: {:ok, plan()} | {:error, reason()}
  def explain(slots, opts \\ []) do
    with :ok <- check_slots(slots),
         {:ok, weights} <- weights(opts),
         {:ok, lookup} <- feature_lookup(opts),
         {:ok, seqs} <- feature_table(slots, lookup) do
      {:ok, build_plan(slots, seqs, weights, opts)}
    end
  end

  @doc """
  Were these two candidates spoken one after the other in the same recording?

  Public because it is the one rule in here that a caller might reasonably want
  to ask about directly — a run of adjacent takes is a phrase the corpus already
  contains, and joining it costs nothing. Order matters: `b` must follow `a`.
  """
  @spec adjacent?(Types.candidate(), Types.candidate(), opts()) :: boolean()
  def adjacent?(a, b, opts \\ [])

  def adjacent?(%{source: src, frame1: f1}, %{source: src, frame0: f0}, opts) do
    abs(f0 - f1) <= positive_int(opts, :adjacent_tolerance_frames, @adjacent_tolerance_frames, 0)
  end

  def adjacent?(_a, _b, _opts), do: false

  # ── Validation ─────────────────────────────────────────────────────────────

  defp check_slots([_ | _] = slots) do
    cond do
      not Enum.all?(slots, &is_list/1) ->
        {:error, :no_slots}

      Enum.any?(slots, &(&1 == [])) ->
        {:error, :empty_slot}

      not Enum.all?(slots, fn slot -> Enum.all?(slot, &candidate?/1) end) ->
        {:error, :bad_candidate}

      true ->
        :ok
    end
  end

  defp check_slots(_other), do: {:error, :no_slots}

  defp candidate?(%{
         source: source,
         word: %{word: word, start_ms: start_ms, end_ms: end_ms, confidence: confidence},
         frame0: frame0,
         frame1: frame1
       })
       when is_binary(source) and is_binary(word) and is_number(start_ms) and is_number(end_ms) and
              is_number(confidence) and is_integer(frame0) and is_integer(frame1) and frame0 >= 0 do
    frame1 >= frame0
  end

  defp candidate?(_other), do: false

  defp weights(opts) do
    supplied =
      case Keyword.get(opts, :weights, %{}) do
        map when is_map(map) -> Enum.to_list(map)
        list when is_list(list) -> list
        _other -> :invalid
      end

    with list when is_list(list) <- supplied,
         true <- Enum.all?(list, &valid_weight?/1) do
      {:ok,
       Enum.reduce(list, @default_weights, fn {key, value}, acc ->
         if Map.has_key?(acc, key), do: Map.put(acc, key, value * 1.0), else: acc
       end)}
    else
      _invalid -> {:error, :bad_weights}
    end
  end

  defp valid_weight?({_key, value}) when is_number(value) and value >= 0, do: true
  defp valid_weight?(_other), do: false

  defp feature_lookup(opts) do
    case Keyword.get(opts, :features, %{}) do
      fun when is_function(fun, 1) -> {:ok, fun}
      map when is_map(map) -> {:ok, fn source -> Map.get(map, source) end}
      _other -> {:error, :bad_features}
    end
  end

  # One sequence per distinct source, validated together: the dimension must be
  # uniform *across* sources as well as within one, because the join cost
  # compares a frame from one recording against a frame from another and a
  # dimension mismatch there is meaningless rather than merely inaccurate.
  defp feature_table(slots, lookup) do
    sources = slots |> Enum.concat() |> Enum.map(& &1.source) |> Enum.uniq()

    Enum.reduce_while(sources, {:ok, %{}, []}, fn source, {:ok, acc, dims} ->
      case lookup.(source) do
        nil ->
          {:cont, {:ok, acc, dims}}

        [] ->
          {:cont, {:ok, acc, dims}}

        seq ->
          case check_seq(seq) do
            {:ok, dim} -> {:cont, {:ok, Map.put(acc, source, seq), [dim | dims]}}
            {:error, _reason} = error -> {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, table, dims} ->
        if length(Enum.uniq(dims)) > 1, do: {:error, :ragged_features}, else: {:ok, table}

      {:error, _reason} = error ->
        error
    end
  end

  defp check_seq(seq) when is_list(seq) do
    if Enum.all?(seq, &vector?/1) do
      case seq |> Enum.map(&length/1) |> Enum.uniq() do
        [dim] -> {:ok, dim}
        _mixed -> {:error, :ragged_features}
      end
    else
      {:error, :bad_features}
    end
  end

  defp check_seq(_other), do: {:error, :bad_features}

  defp vector?([_ | _] = vec), do: Enum.all?(vec, &is_number/1)
  defp vector?(_other), do: false

  # ── The plan ───────────────────────────────────────────────────────────────

  defp build_plan(slots, seqs, weights, opts) do
    settings = settings(opts)
    flat = index_candidates(slots)
    slices = slice_table(flat, seqs)
    seams = seam_table(flat, slices, settings.seam_frames)

    {targets, target_imputed} = target_costs(flat, slices, weights, settings)
    {joins, join_imputed} = join_costs(slots, seams, weights, settings)

    {total, keys} = viterbi(slots, targets, joins)

    by_key = Map.new(flat)
    path = Enum.map(keys, fn key -> Map.fetch!(by_key, key) end)
    chosen_targets = Enum.map(keys, &Map.fetch!(targets, &1))
    chosen_joins = chosen_joins(keys, joins)

    %{
      cuts: Enum.map(path, &to_cut/1),
      path: path,
      targets: chosen_targets,
      joins: chosen_joins,
      target_total: sum_of(chosen_targets),
      join_total: sum_of(chosen_joins),
      total: total,
      weights: weights,
      imputed: Map.put(target_imputed, :join, join_imputed),
      slots: length(slots),
      candidates: length(flat)
    }
  end

  defp to_cut(%{source: source, word: word}) do
    %{source: source, start_ms: word.start_ms * 1.0, end_ms: word.end_ms * 1.0}
  end

  defp sum_of(costs), do: Enum.reduce(costs, 0.0, fn cost, acc -> acc + cost.total end)

  defp chosen_joins(keys, joins) do
    keys
    |> Enum.zip(tl(keys))
    |> Enum.map(fn {{slot, a}, {_next, b}} -> Map.fetch!(joins, {slot, a, b}) end)
  end

  defp settings(opts) do
    %{
      syllable_ms: positive_number(opts, :syllable_ms, @syllable_ms),
      seam_frames: positive_int(opts, :seam_frames, @seam_frames, 1),
      adjacent_tolerance:
        positive_int(opts, :adjacent_tolerance_frames, @adjacent_tolerance_frames, 0),
      max_siblings: positive_int(opts, :max_siblings, @max_siblings, 1),
      normalize: if(Keyword.get(opts, :normalize, :minmax) == :none, do: :none, else: :minmax),
      boundary: boundary_fun(opts)
    }
  end

  defp positive_number(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_number(value) and value > 0 -> value * 1.0
      _invalid -> default
    end
  end

  defp positive_int(opts, key, default, floor) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= floor -> value
      _invalid -> default
    end
  end

  defp boundary_fun(opts) do
    case Keyword.get(opts, :boundary) do
      fun when is_function(fun, 1) ->
        fun

      map when is_map(map) ->
        fn candidate -> Map.get(map, {candidate.source, candidate.frame0}) end

      _absent ->
        fn _candidate -> nil end
    end
  end

  # `{slot_index, candidate_index}` is the identity of a lattice cell, and the
  # order of this list is the order every normalisation population is built in —
  # which is what makes the whole module deterministic without sorting anything.
  defp index_candidates(slots) do
    slots
    |> Enum.with_index()
    |> Enum.flat_map(fn {slot, i} ->
      slot |> Enum.with_index() |> Enum.map(fn {candidate, j} -> {{i, j}, candidate} end)
    end)
  end

  # ── Slices and seams ───────────────────────────────────────────────────────

  # `frame1` is inclusive — it is the last frame of the take, the same convention
  # `t:Types.match/0` reports its `end_frame` under.
  defp slice_table(flat, seqs) do
    Map.new(flat, fn {key, candidate} ->
      slice =
        case Map.get(seqs, candidate.source) do
          nil ->
            nil

          seq ->
            case Enum.slice(seq, candidate.frame0, candidate.frame1 - candidate.frame0 + 1) do
              [] -> nil
              frames -> frames
            end
        end

      {key, slice}
    end)
  end

  defp seam_table(flat, slices, seam_frames) do
    Map.new(flat, fn {key, _candidate} ->
      case Map.fetch!(slices, key) do
        nil ->
          {key, nil}

        slice ->
          head = slice |> Enum.take(seam_frames) |> mean_vector()
          tail = slice |> Enum.take(-seam_frames) |> mean_vector()
          {key, %{head: head, tail: tail}}
      end
    end)
  end

  defp mean_vector([first | _rest] = vectors) do
    count = length(vectors)
    zeros = List.duplicate(0.0, length(first))

    vectors
    |> Enum.reduce(zeros, fn vec, acc -> Enum.zip_with(vec, acc, &(&1 + &2)) end)
    |> Enum.map(&(&1 / count))
  end

  # ── Target cost ────────────────────────────────────────────────────────────

  defp target_costs(flat, slices, weights, settings) do
    confidence =
      Enum.map(flat, fn {_key, candidate} -> 1.0 - clamp(candidate.word.confidence) end)

    duration = Enum.map(flat, fn {_key, candidate} -> duration_raw(candidate, settings) end)

    boundary =
      Enum.map(flat, fn {_key, candidate} -> number_or_nil(settings.boundary.(candidate)) end)

    typicality = typicality_raws(flat, slices, settings)

    costs =
      [confidence, duration, boundary, typicality]
      |> Enum.map(&normalise(&1, settings.normalize))
      |> Enum.zip()
      |> Enum.map(fn {conf, dur, bnd, typ} ->
        %{
          confidence: weights.confidence * conf,
          duration: weights.duration * dur,
          boundary: weights.boundary * bnd,
          typicality: weights.typicality * typ
        }
        |> with_total()
      end)

    table =
      flat
      |> Enum.map(fn {key, _candidate} -> key end)
      |> Enum.zip(costs)
      |> Map.new()

    imputed = %{
      boundary: Enum.count(boundary, &is_nil/1),
      typicality: Enum.count(typicality, &is_nil/1)
    }

    {table, imputed}
  end

  defp with_total(terms), do: Map.put(terms, :total, terms |> Map.values() |> Enum.sum())

  defp clamp(value) when is_number(value), do: value |> max(0.0) |> min(1.0) |> Kernel.*(1.0)

  defp number_or_nil(value) when is_number(value), do: value * 1.0
  defp number_or_nil(_other), do: nil

  # A Gaussian in the log of (actual / expected), the same shape `Align` scores a
  # duration with — half and double are equally wrong, and a linear error is not.
  # Returned as a *penalty*, so 0.0 is a duration exactly where it should be.
  defp duration_raw(candidate, settings) do
    actual = candidate.word.end_ms - candidate.word.start_ms
    expected = Align.syllables(candidate.word.word) * settings.syllable_ms

    if actual > 0.0 and expected > 0.0 do
      error = :math.log(actual / expected) / @log_tolerance
      1.0 - :math.exp(-0.5 * error * error)
    else
      1.0
    end
  end

  defp typicality_raws(flat, slices, settings) do
    by_word =
      Enum.group_by(
        flat,
        fn {_key, candidate} -> candidate.word.word end,
        fn {key, _candidate} -> key end
      )

    Enum.map(flat, fn {key, candidate} ->
      case Map.fetch!(slices, key) do
        nil ->
          nil

        slice ->
          by_word
          |> Map.fetch!(candidate.word.word)
          |> Enum.reject(&(&1 == key))
          |> sample(settings.max_siblings)
          |> Enum.map(&Map.fetch!(slices, &1))
          |> Enum.reject(&is_nil/1)
          |> mean_distance(slice)
      end
    end)
  end

  defp mean_distance([], _slice), do: nil

  defp mean_distance(siblings, slice) do
    distances =
      siblings
      |> Enum.map(fn sibling ->
        case Dtw.distance(slice, sibling) do
          {:error, _reason} -> nil
          distance -> distance
        end
      end)
      |> Enum.reject(&is_nil/1)

    case distances do
      [] -> nil
      values -> Enum.sum(values) / length(values)
    end
  end

  # Evenly spaced rather than the first N, so a candidate is compared against the
  # spread of its siblings and not against whichever handful happens to be listed
  # first. Deterministic: no randomness anywhere in this module.
  defp sample(list, count) do
    total = length(list)

    if total <= count do
      list
    else
      Enum.map(0..(count - 1), fn i -> Enum.at(list, div(i * total, count)) end)
    end
  end

  # ── Join cost ──────────────────────────────────────────────────────────────

  defp join_costs(slots, seams, weights, settings) do
    pairs = join_pairs(slots, seams, settings)

    spectral = Enum.map(pairs, fn {_key, _natural, spec, _lev} -> spec end)
    level = Enum.map(pairs, fn {_key, _natural, _spec, lev} -> lev end)

    normalised =
      [normalise(spectral, settings.normalize), normalise(level, settings.normalize)]
      |> Enum.zip()

    table =
      pairs
      |> Enum.zip(normalised)
      |> Map.new(fn {{key, natural, _spec, _lev}, {spec, lev}} ->
        cost =
          if natural do
            %{spectral: 0.0, level: 0.0, total: 0.0}
          else
            with_total(%{spectral: weights.spectral * spec, level: weights.level * lev})
          end

        {key, cost}
      end)

    # A natural run is free by rule, so it is never counted as a gap in the data.
    imputed =
      Enum.count(pairs, fn {_key, natural, spec, _lev} -> not natural and is_nil(spec) end)

    {table, imputed}
  end

  defp join_pairs(slots, seams, settings) do
    slots
    |> Enum.zip(tl(slots))
    |> Enum.with_index()
    |> Enum.flat_map(fn {{left, right}, i} ->
      for {a, ai} <- Enum.with_index(left), {b, bi} <- Enum.with_index(right) do
        {spec, lev} = seam_raw(seams[{i, ai}], seams[{i + 1, bi}])
        {{i, ai, bi}, adjacent_pair?(a, b, settings), spec, lev}
      end
    end)
  end

  defp adjacent_pair?(%{source: src, frame1: f1}, %{source: src, frame0: f0}, settings),
    do: abs(f0 - f1) <= settings.adjacent_tolerance

  defp adjacent_pair?(_a, _b, _settings), do: false

  # The raw seam measurement is taken even for a natural run: the pair still
  # belongs to the population the scale is derived from, so one free join cannot
  # compress every other join toward zero. The rule is applied after.
  defp seam_raw(%{tail: tail}, %{head: head}),
    do: {spectral_distance(tail, head), level_distance(tail, head)}

  defp seam_raw(_left, _right), do: {nil, nil}

  # Coefficient 0 of an MFCC frame is its log energy, so it belongs to the level
  # term and must be kept out of the spectral one — otherwise the two terms
  # measure the same jump twice and the weights stop separating them.
  defp spectral_distance([_c0_a | rest_a], [_c0_b | rest_b]) do
    :math.sqrt(sum_squares(rest_a, rest_b, 0.0))
  end

  defp sum_squares([], [], acc), do: acc

  defp sum_squares([a | as], [b | bs], acc) do
    d = a - b
    sum_squares(as, bs, acc + d * d)
  end

  defp level_distance([c0_a | _rest_a], [c0_b | _rest_b]), do: abs(c0_a - c0_b)

  # ── Normalisation ──────────────────────────────────────────────────────────

  # Min–max over the pooled population, with two deliberate degeneracies:
  #
  #   * no spread at all -> every value becomes 0.0. A constant term carries no
  #     information about which candidate to pick, so it must be silent rather
  #     than arbitrary — and 0.0 keeps it out of the reported totals too.
  #   * a missing value -> the median of the observable population, mapped
  #     through the same transform. Neither a reward nor a punishment for data
  #     that was not injected; `explain/2` reports how often it happened.
  defp normalise(raws, :none),
    do:
      Enum.map(raws, fn
        nil -> 0.0
        value -> value * 1.0
      end)

  defp normalise(raws, :minmax) do
    present = Enum.reject(raws, &is_nil/1)

    case present do
      [] ->
        Enum.map(raws, fn _ -> 0.0 end)

      values ->
        low = Enum.min(values)
        span = Enum.max(values) - low

        if span <= 0.0 do
          Enum.map(raws, fn _ -> 0.0 end)
        else
          fill = (median(values) - low) / span

          Enum.map(raws, fn
            nil -> fill
            value -> (value - low) / span
          end)
        end
    end
  end

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, middle)
    else
      (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2.0
    end
  end

  # ── Viterbi ────────────────────────────────────────────────────────────────

  # One column at a time, as `Dtw` does — but carrying the winning path in the
  # cell instead of backtracking, because a sentence-sized lattice can afford a
  # list of slot indices per cell where a 1.8M-cell DTW matrix cannot.
  #
  # Every improvement test is strict `<` and every scan runs in the caller's
  # candidate order, which is precisely the documented tie-break: among
  # equal-cost paths, the earlier-listed candidate wins, resolved from the last
  # slot backwards.
  defp viterbi(slots, targets, joins) do
    [first | rest] = Enum.with_index(slots)

    initial =
      first
      |> column_keys()
      |> Enum.map(fn key -> {Map.fetch!(targets, key).total, [key]} end)

    rest
    |> Enum.reduce(initial, fn {_slot, i} = indexed, previous ->
      indexed
      |> column_keys()
      |> Enum.map(fn {^i, bi} = key ->
        {cost, path} = cheapest_predecessor(previous, i - 1, bi, joins)
        {cost + Map.fetch!(targets, key).total, [key | path]}
      end)
    end)
    |> Enum.reduce(nil, &keep_cheaper/2)
    |> then(fn {cost, path} -> {cost, Enum.reverse(path)} end)
  end

  defp column_keys({slot, i}), do: Enum.map(0..(length(slot) - 1), fn j -> {i, j} end)

  defp cheapest_predecessor(previous, seam, bi, joins) do
    previous
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {{cost, path}, ai}, best ->
      candidate = {cost + Map.fetch!(joins, {seam, ai, bi}).total, path}
      keep_cheaper(candidate, best)
    end)
  end

  defp keep_cheaper(candidate, nil), do: candidate

  defp keep_cheaper({cost, _path} = candidate, {best_cost, _best_path} = best) do
    if cost < best_cost, do: candidate, else: best
  end
end
