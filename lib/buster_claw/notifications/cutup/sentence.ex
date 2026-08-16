defmodule BusterClaw.Notifications.Cutup.Sentence do
  @moduledoc """
  Phrase in, spliced clip out — the core of building a ramshackle sentence.

  Extracted from `Commands.Sound.sound_sentence/1` on 08-16 so the Voice Library
  surface and the command surface splice through **one implementation**. The
  alternative was a second builder in the web layer, and two sentence builders
  would have drifted on exactly the details that decide whether the result is
  audible — padding, fade, and which take of each word gets chosen.

  A LiveView may not call `Commands.call/3` (it would run as `:trusted` with no
  token; see `remote_mode_test.exs`), and reaching into `Commands.Sound` from the
  web layer would be the same mistake wearing a different name. So the shared
  thing is a domain module, which is the shape `Capture.Take` already took.

  ## What this owns, and what it does not

  It owns the four steps between a phrase and audio:

      phrase
        └─ tokens          normalized the way the corpus is keyed
        └─ slots           every take of each word, best-confidence first
        └─ plan            `Cutup.Select` choosing between them
        └─ clip            `Cutup.Assemble` splicing with padding and fades

  It does **not** name files, write them, or decide what a result looks like on
  the wire. `sound_sentence` keeps all of that, because a command's arguments and
  its reply shape are the command's business.

  ## Missing words are fatal by default, and the error names them

  `{:error, {:words_not_found, ["zebra"]}}` rather than `:no_takes`, because *"you
  have no take of zebra"* is actionable and a bare refusal is not. `allow_missing`
  is for a caller who has already said they will accept a partial sentence and
  would otherwise get an empty one.

  ## The bank is not optional here

  `:bank` narrows every lookup to one voice. Splicing across banks is the single
  thing `Cutup.Bank` exists to prevent — a phrase assembled from two speakers
  sounds broken, and `Cutup.Select` would cheerfully choose a stranger's take
  because it ranks on acoustic fit, not on identity. Callers pass the active
  bank; omitting it searches every bank and is almost never what anyone wants.
  """

  alias BusterClaw.Notifications.Cutup.Assemble
  alias BusterClaw.Notifications.Cutup.Features
  alias BusterClaw.Notifications.Cutup.Index
  alias BusterClaw.Notifications.Cutup.Select
  alias BusterClaw.Notifications.Cutup.Signal
  alias BusterClaw.Notifications.Cutup.Takes

  @typedoc """
  A built sentence.

  `missing` is the words that had no take and were skipped — present only when
  the caller allowed them, and never silently.
  """
  @type built :: %{
          clip: BusterClaw.Notifications.SoundStudio.t(),
          plan: map(),
          slots: [map()],
          missing: [String.t()],
          features: map()
        }

  @typedoc "Why a sentence could not be built."
  @type error ::
          :empty_phrase
          | :no_takes
          | {:words_not_found, [String.t()]}
          | term()

  @doc """
  Build the clip for a phrase.

  Options:

    * `:bank` — the voice to splice from. See the moduledoc; pass it.
    * `:allow_missing` — accept a partial sentence (default `false`).
    * `:warm` — compute acoustic features for sources that have none cached,
      which improves selection and costs ~109 s per uncached source. Default
      `false`, so an interactive caller stays interactive.
    * `:index` — extra narrowing passed to `Index.search/2` (`:limit`,
      `:min_confidence`).
    * `:weights` — `Cutup.Select` weights.
    * `:assemble` — `Cutup.Assemble` options (padding, fades).
  """
  @spec build(term(), keyword()) :: {:ok, built()} | {:error, error()}
  def build(phrase, opts \\ [])

  def build(phrase, opts) when is_binary(phrase) and is_list(opts) do
    with {:ok, tokens} <- tokens(phrase),
         {:ok, slots, missing} <-
           slots(tokens, index_opts(opts), allow_missing?(opts), Keyword.get(opts, :bank)),
         features = features(slots, Keyword.get(opts, :warm, false)),
         {:ok, plan} <-
           Select.explain(candidates(slots), [features: features.table] ++ weights(opts)),
         {:ok, clip} <- Assemble.build(plan.cuts, Keyword.get(opts, :assemble, [])) do
      {:ok,
       %{
         clip: clip,
         plan: plan,
         slots: slots,
         missing: Enum.map(missing, & &1.text),
         features: features
       }}
    end
  end

  def build(_phrase, _opts), do: {:error, :empty_phrase}

  @doc """
  Split a phrase into the tokens the corpus is keyed on.

  Public because the grading half of the Voice Library asks the same question
  without building anything, and a second tokenizer would be a second definition
  of "what counts as a word".
  """
  @spec tokens(term()) :: {:ok, [%{text: String.t(), word: String.t()}]} | {:error, :empty_phrase}
  def tokens(phrase) when is_binary(phrase) do
    tokens =
      phrase
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.map(fn text -> %{text: text, word: Index.normalize_word(text)} end)
      |> Enum.reject(&(&1.word == ""))

    if tokens == [], do: {:error, :empty_phrase}, else: {:ok, tokens}
  end

  def tokens(_phrase), do: {:error, :empty_phrase}

  # ---------------------------------------------------------------------------
  # Internals — moved verbatim from Commands.Sound, comments included
  # ---------------------------------------------------------------------------

  defp slots(tokens, opts, allow_missing?, bank) do
    {found, missing} =
      tokens
      |> Enum.map(fn token ->
        # The operator's chosen take wins over the lattice. `pin/3` narrows the
        # candidates to it when one is set and still exists, and falls through to
        # the full list when it does not — a preference that has outlived its
        # take costs a worse splice, never a refusal (`Cutup.Takes`).
        hits = token.word |> Index.search(opts) |> pinned(bank, token.word)
        Map.put(token, :hits, hits)
      end)
      |> Enum.split_with(&(&1.hits != []))

    # Naming the words comes first even when NOTHING was found: "you have no take
    # of zebra" is actionable and ":no_takes" is not. The bare refusal is left
    # for the caller who already said they would accept a partial sentence and
    # would otherwise get an empty one.
    cond do
      missing != [] and not allow_missing? ->
        {:error, {:words_not_found, Enum.map(missing, & &1.text)}}

      found == [] ->
        {:error, :no_takes}

      true ->
        {:ok, found, missing}
    end
  end

  # `Index.search/2` returns best-confidence-first and that order is carried
  # into the candidate list, so `Select` receives them ranked.
  defp candidates(slots) do
    Enum.map(slots, fn slot ->
      Enum.map(slot.hits, fn hit ->
        frame0 = frame_at(hit.word.start_ms)

        %{
          source: hit.source,
          word: hit.word,
          frame0: frame0,
          frame1: max(frame_at(hit.word.end_ms) - 1, frame0)
        }
      end)
    end)
  end

  # Only when a bank was named. Preferences are per-bank by construction, so a
  # corpus-wide search has no "the chosen one" to apply.
  defp pinned(hits, bank, word) when is_binary(bank), do: Takes.pin(hits, bank, word)
  defp pinned(hits, _bank, _word), do: hits

  defp frame_at(ms), do: max(trunc(ms / Signal.hop_ms()), 0)

  defp features(slots, warm?) do
    sources =
      slots |> Enum.flat_map(fn slot -> Enum.map(slot.hits, & &1.source) end) |> Enum.uniq()

    cold = Enum.reject(sources, &Features.cached?/1)
    wanted = if warm?, do: sources, else: sources -- cold

    if warm? and cold != [], do: Features.warm(cold)

    table =
      Enum.reduce(wanted, %{}, fn source, acc ->
        case Features.for_source(source) do
          {:ok, [_ | _] = seq} -> Map.put(acc, source, seq)
          _other -> acc
        end
      end)

    %{
      table: table,
      warm: warm?,
      sources: Enum.sort(sources),
      with_features: table |> Map.keys() |> Enum.sort(),
      without_features: Enum.sort(sources -- Map.keys(table)),
      analysed: if(warm?, do: Enum.sort(cold), else: [])
    }
  end

  defp allow_missing?(opts), do: Keyword.get(opts, :allow_missing, false) == true

  defp weights(opts), do: Keyword.get(opts, :weights, [])

  # `:bank` rides on the index options because that is where `Index.search/2`
  # reads it. Kept as a merge rather than an override so a caller narrowing by
  # `:source` or `:limit` keeps both.
  defp index_opts(opts) do
    base = Keyword.get(opts, :index, [])

    case Keyword.get(opts, :bank) do
      nil -> base
      bank -> Keyword.put(base, :bank, bank)
    end
  end
end
