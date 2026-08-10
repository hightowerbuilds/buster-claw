defmodule BusterClaw.Notifications.Cutup.Gaps do
  @moduledoc """
  *"What words am I missing?"* — a read-only coverage report over the word indexes
  (STUDIO_ROADMAP V.4b, and the first half of the dictionary's Pane 1 in VI.1).

  Two of the three documents that planned the cut-up named this as the first thing
  to build, because it is the difference between a *designed* donor passage and a
  guessed one: read an hour of new material against this report and the hour
  targets real gaps, instead of re-covering words the voicemails already say
  thirty-five times.

  ## The one number that matters

  **A word with one take is a quotation, not a cut-up.** Splicing a word that
  exists exactly once reproduces the speaker saying it, at the one pitch and pace
  they happened to use; there was no choice to make and nothing was assembled.
  `single_take` is that list and `cuttable` is its complement — everything else
  here is context for those two.

  ## What it reads, and what it does not re-implement

  `Cutup.Index` owns the on-disk format. This module calls its public
  `list/0`, `load/1` and `normalize_word/1` and parses nothing itself: a second
  reader for the same JSON is exactly the drift the index moduledoc warns about.
  One consequence worth stating — `Index.load/1` re-reads every file on every
  call, so a report is a fresh measurement rather than a cached one.

  The load happens once here, in a single pass, and the frequency map is derived
  from that pass rather than from `Index.words_available/1`. Not a duplicated
  computation: `origins` needs the per-file header that `words_available/1`
  discards, and calling both would read the whole corpus twice and let the two
  halves of one report disagree if a file changed in between.

  ## `origins` counts takes, and origin is a property of the FILE

  Measured against the real corpus (ten voicemails, 08-09): `origin` appears once
  per index file and **never on an individual word entry** — `Index` would drop a
  per-word one on the way in, so a hand-edited file could not introduce one
  either. Every take therefore inherits its source's origin, which is why
  `origins` sums to `total_takes`. All four origins are always present, zeros
  included, so a caller can read `origins["manual"]` without a `nil` check and so
  an empty corpus reports zeros rather than an absent key.

  Read it as a confidence ceiling: `aligned` is a proportional guess (caps at
  0.9), `recognizer` is MFCC + DTW, and `manual` is the only origin that earns
  1.0. A vocabulary that is entirely `aligned` is a vocabulary of estimates.

  ## Empty is a number, not a failure

  A workspace with no `sounds/studio/index/` directory reports zeros. The corpus
  lives under the operator's configured DataZone, so a dev workspace legitimately
  has none of it, and `sound_corpus` already answers that with a count rather
  than an error — this matches. `{:error, reason}` is reserved for a directory
  that exists and cannot be read (permissions, or a file where a directory
  belongs), which is a real fault rather than an empty shelf.
  """

  alias BusterClaw.Notifications.Cutup.Index
  alias BusterClaw.Notifications.Cutup.Types

  @origins ["aligned", "manual", "recognizer", "imported"]

  @typedoc """
  Options for `report/1`.

  `:limit` caps `by_take_count` **after** sorting, so it keeps the most-covered
  words; anything that is not a positive integer is ignored rather than refused,
  matching `Index.search/2`. `:target` adds the `missing` key.
  """
  @type opts :: [limit: pos_integer(), target: [String.t()] | String.t()]

  @typedoc """
  Vocabulary coverage of the indexed corpus.

  `missing` is present only when `:target` was given. `unreadable_sources` counts
  index files that are on disk and could not be loaded — corrupt JSON, or a name
  that no longer passes the source gate — because a report that quietly dropped
  them would understate the corpus without saying so.
  """
  @type report :: %{
          required(:indexed_sources) => non_neg_integer(),
          required(:unreadable_sources) => non_neg_integer(),
          required(:distinct_words) => non_neg_integer(),
          required(:total_takes) => non_neg_integer(),
          required(:cuttable) => non_neg_integer(),
          required(:single_take) => [String.t()],
          required(:by_take_count) => [{String.t(), pos_integer()}],
          required(:origins) => %{String.t() => non_neg_integer()},
          optional(:missing) => [String.t()]
        }

  @typedoc "Why a report was refused. Returned, never raised."
  @type error :: :invalid_opts | :invalid_target | :file.posix()

  @doc """
  Vocabulary coverage of the indexed corpus.

  `by_take_count` is sorted by take count descending, then by word ascending, and
  `single_take` alphabetically. The order is part of the contract: an unstable one
  makes the report untestable and the dictionary's Pane 1 jumpy.

  With `:target` — a list of words, or one string that is split on whitespace —
  the report also carries `missing`: the target words with **zero** takes, sorted
  and de-duplicated. Target words are run through `Index.normalize_word/1` first,
  because the corpus is keyed on the normalized form; `missing` therefore reports
  normalized words, and target entries that normalize to nothing (pure
  punctuation) are dropped rather than reported as missing forever.

  A word present in `missing` can only be spliced from something not yet
  recorded. A target word absent from `missing` but present in `single_take` is
  the more interesting case: you have it once, so you can quote it but not cut it.
  """
  @spec report(opts()) :: {:ok, report()} | {:error, error()}
  def report(opts \\ [])

  def report(opts) when is_list(opts) do
    with {:ok, target} <- target(Keyword.get(opts, :target)),
         {:ok, sources} <- sources() do
      {:ok, sources |> load() |> summarize(limit(opts), target)}
    end
  end

  def report(_opts), do: {:error, :invalid_opts}

  # ---------------------------------------------------------------------------
  # Reading
  # ---------------------------------------------------------------------------

  # `Index.list/0` has no error channel — it answers `[]` for both "no directory"
  # and "cannot read the directory". Those need different reports, so the
  # readability question is asked directly and the naming rules are still left to
  # `list/0` rather than re-derived here.
  @spec sources() :: {:ok, [String.t()]} | {:error, error()}
  defp sources do
    case File.ls(Index.dir()) do
      {:ok, _entries} -> {:ok, Index.list()}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # Kept as {loaded, attempted} so `unreadable_sources` can be reported as a
  # number instead of vanishing.
  @spec load([String.t()]) :: {[Types.index()], non_neg_integer()}
  defp load(sources) do
    loaded =
      Enum.flat_map(sources, fn source ->
        case Index.load(source) do
          {:ok, index} -> [index]
          {:error, _reason} -> []
        end
      end)

    {loaded, length(sources)}
  end

  # ---------------------------------------------------------------------------
  # Counting
  # ---------------------------------------------------------------------------

  @spec summarize({[Types.index()], non_neg_integer()}, pos_integer() | nil, [String.t()] | nil) ::
          report()
  defp summarize({indexes, attempted}, limit, target) do
    takes = indexes |> Enum.flat_map(& &1.words) |> Enum.frequencies_by(& &1.word)

    %{
      indexed_sources: length(indexes),
      unreadable_sources: attempted - length(indexes),
      distinct_words: map_size(takes),
      total_takes: takes |> Map.values() |> Enum.sum(),
      cuttable: Enum.count(takes, fn {_word, count} -> count >= 2 end),
      single_take: takes |> with_count(1) |> Enum.sort(),
      by_take_count: takes |> ranked() |> cap(limit),
      origins: origins(indexes)
    }
    |> put_missing(target, takes)
  end

  @spec with_count(%{String.t() => pos_integer()}, pos_integer()) :: [String.t()]
  defp with_count(takes, count) do
    for {word, ^count} <- takes, do: word
  end

  # Count descending so the best-covered word leads, then alphabetical so ties
  # never reorder between two runs over the same files.
  @spec ranked(%{String.t() => pos_integer()}) :: [{String.t(), pos_integer()}]
  defp ranked(takes), do: Enum.sort_by(takes, fn {word, count} -> {-count, word} end)

  @spec cap([tuple()], pos_integer() | nil) :: [tuple()]
  defp cap(ranked, nil), do: ranked
  defp cap(ranked, limit), do: Enum.take(ranked, limit)

  # Every take inherits its file's origin — see the moduledoc on why there is no
  # per-word one to prefer. Zeros are kept so the shape never changes.
  @spec origins([Types.index()]) :: %{String.t() => non_neg_integer()}
  defp origins(indexes) do
    counted =
      Enum.reduce(indexes, %{}, fn index, acc ->
        Map.update(acc, origin_name(index), length(index.words), &(&1 + length(index.words)))
      end)

    @origins |> Map.new(&{&1, 0}) |> Map.merge(counted)
  end

  # Total, with no fallback clause, because `Index.load/1` always names one of the
  # four: it is the reader that decides, and a file whose `origin` is unparseable
  # is already reported here as `manual` by its ruling. Worth knowing when a count
  # looks too trustworthy — `manual` is the origin that earns 1.0, so a corrupt
  # header flatters itself.
  defp origin_name(%{origin: origin}), do: Atom.to_string(origin)

  # ---------------------------------------------------------------------------
  # Target vocabulary
  # ---------------------------------------------------------------------------

  @spec target(term()) :: {:ok, [String.t()] | nil} | {:error, error()}
  defp target(nil), do: {:ok, nil}

  defp target(words) when is_binary(words) do
    words |> String.split(~r/\s+/u, trim: true) |> target()
  end

  defp target(words) when is_list(words) do
    if Enum.all?(words, &is_binary/1) do
      {:ok, words |> Enum.map(&Index.normalize_word/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()}
    else
      {:error, :invalid_target}
    end
  end

  defp target(_words), do: {:error, :invalid_target}

  @spec put_missing(report(), [String.t()] | nil, %{String.t() => pos_integer()}) :: report()
  defp put_missing(report, nil, _takes), do: report

  defp put_missing(report, target, takes) do
    Map.put(report, :missing, target |> Enum.reject(&Map.has_key?(takes, &1)) |> Enum.sort())
  end

  # ---------------------------------------------------------------------------
  # Options
  # ---------------------------------------------------------------------------

  defp limit(opts) do
    case Keyword.get(opts, :limit) do
      value when is_integer(value) and value > 0 -> value
      _other -> nil
    end
  end
end
