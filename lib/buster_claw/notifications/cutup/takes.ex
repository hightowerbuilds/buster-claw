defmodule BusterClaw.Notifications.Cutup.Takes do
  @moduledoc """
  Curating the takes of a word: which ones exist, which one wins, and which one
  should stop existing.

  The corpus grows by recording, and a corpus that only grows is a corpus nobody
  can steer. This module is the other half — the operator listens to four takes
  of *harbor*, decides the second is the good one, and throws away the one where
  the chair creaked.

  ## Preference is a POINTER, not a score

  "Use this take" is stored as `{bank, word} → {source, start_ms}` and applied at
  selection time by `Cutup.Sentence`. The rejected alternative was bumping the
  chosen take's `confidence`, which is worse in three specific ways:

  - **It corrupts a measurement.** `confidence` records how the timings were
    produced (`Cutup.Types`); a `:manual` take earns 1.0 by being marked by ear.
    Writing 1.0 onto an `:aligned` take to express a preference makes the origin
    field lie, and the origin field is what the whole corpus's trust rests on.
  - **It is not reversible.** The previous value is gone, so "actually, use the
    other one" cannot restore what was there.
  - **It cannot be per-bank.** Confidence lives in the index, which is per source.
    The same source could be preferred in one voice and not another once banks
    can be re-attributed.

  A pointer is none of those things. It is also inert: delete the preference and
  selection reverts to `Cutup.Select` doing its job.

  ## A dangling preference is not an error

  The take it names can be deleted, or the file can vanish. `preferred/2` answers
  with whatever is stored; `pin/2` — the function `Cutup.Sentence` actually uses —
  matches it against the hits that exist and **falls back silently to the full
  candidate list** when nothing matches. A preference that has outlived its take
  should cost a slightly worse splice, never a refusal.

  ## Deleting a take deletes an ENTRY, and sometimes a file

  A take is one word inside one source's index, so `delete/2` removes that entry.
  What happens next depends on what is left:

  | After removal | Index | Audio |
  |---|---|---|
  | other words remain | rewritten | kept |
  | no words left, source was a one-word `:manual` recording | deleted | **deleted** |
  | no words left, anything else | deleted | kept |

  The middle row is the case the operator means when they say "delete this take":
  a file recorded for that word alone, now unwanted, and leaving the audio would
  leave litter with no purpose. The bottom row is the guard — a voicemail whose
  words were removed one by one is still a recording somebody made, and V.7's
  sample-rate policy is explicit that the masters are the only way back.
  """

  alias BusterClaw.Notifications.Cutup.Index
  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Settings

  @key "studio.voice.preferred"

  # A take is addressed by its source and its start offset. Floats are compared
  # after rounding to this many places, because the offset makes a round trip
  # through JSON and the DOM before it comes back to identify a take.
  @places 3

  @typedoc "Where a preferred take lives."
  @type ref :: %{source: String.t(), start_ms: float()}

  @doc """
  Every take of a word in a bank, best first, each marked with whether it is the
  preferred one.

  The order is `Index.search/2`'s — confidence descending, then source and start
  — so the list is stable enough to render and to click through. Preference does
  not reorder it: moving the chosen take to the top would make the list jump
  under the operator every time they change their mind.
  """
  @spec list(String.t(), String.t()) :: [map()]
  def list(bank, word) when is_binary(bank) and is_binary(word) do
    chosen = preferred(bank, word)

    word
    |> Index.search(bank: bank, limit: 50)
    |> Enum.map(fn hit -> Map.put(hit, :preferred?, same?(hit, chosen)) end)
  end

  def list(_bank, _word), do: []

  @doc "The stored preference for a word, or `nil`."
  @spec preferred(String.t(), String.t()) :: ref() | nil
  def preferred(bank, word) when is_binary(bank) and is_binary(word) do
    get_in(all(), [bank, Index.normalize_word(word)])
  end

  def preferred(_bank, _word), do: nil

  @doc """
  Choose the take of `word` that should be used, addressed by source and offset.

  Refuses a take that does not exist (`:no_such_take`) rather than storing a
  pointer to nothing — a preference the operator cannot see the effect of is
  worse than none.
  """
  @spec prefer(String.t(), String.t(), String.t(), number()) ::
          {:ok, ref()} | {:error, :no_such_take}
  def prefer(bank, word, source, start_ms)
      when is_binary(bank) and is_binary(word) and is_binary(source) and is_number(start_ms) do
    ref = %{source: source, start_ms: round_ms(start_ms)}

    if Enum.any?(Index.search(word, bank: bank, limit: 50), &same?(&1, ref)) do
      write(put_in_map(all(), bank, Index.normalize_word(word), ref))
      {:ok, ref}
    else
      {:error, :no_such_take}
    end
  end

  def prefer(_bank, _word, _source, _start_ms), do: {:error, :no_such_take}

  @doc "Forget the preference for a word — selection goes back to `Cutup.Select`."
  @spec unprefer(String.t(), String.t()) :: :ok
  def unprefer(bank, word) when is_binary(bank) and is_binary(word) do
    normalized = Index.normalize_word(word)
    map = all()

    case Map.get(map, bank) do
      nil -> :ok
      words -> write(Map.put(map, bank, Map.delete(words, normalized)))
    end
  end

  def unprefer(_bank, _word), do: :ok

  @doc """
  Narrow a slot's candidate hits to the preferred take, if one exists and is
  present.

  This is the function `Cutup.Sentence` calls, and it is deliberately total: a
  preference naming a take that is gone falls through to the full list rather
  than emptying the slot. See the moduledoc on why a dangling pointer is not an
  error.
  """
  @spec pin([map()], String.t(), String.t()) :: [map()]
  def pin(hits, bank, word) do
    case preferred(bank, word) do
      nil ->
        hits

      ref ->
        case Enum.filter(hits, &same?(&1, ref)) do
          [] -> hits
          [_ | _] = pinned -> pinned
        end
    end
  end

  @doc """
  Remove one take from the corpus.

  See the moduledoc's table for what happens to the index and the audio. Returns
  what was actually removed so a caller can say so honestly.
  """
  @spec delete(String.t(), number()) ::
          {:ok, %{index: boolean(), audio: boolean()}} | {:error, term()}
  def delete(source, start_ms) when is_binary(source) and is_number(start_ms) do
    with {:ok, index} <- Index.load(source) do
      target = round_ms(start_ms)
      {removed, kept} = Enum.split_with(index.words, &(round_ms(&1.start_ms) == target))

      cond do
        removed == [] -> {:error, :no_such_take}
        kept == [] -> drop_source(source, index)
        true -> keep_rest(index, kept)
      end
    end
  end

  def delete(_source, _start_ms), do: {:error, :no_such_take}

  @doc """
  Drop every preference that names a take which no longer exists.

  Not called on the hot path — a dangling pointer is harmless by construction
  (`pin/3` falls through). This is for a caller that wants the stored state to
  match reality, and it is cheap only because the corpus is small.
  """
  @spec prune() :: :ok
  def prune do
    map = all()

    pruned =
      Map.new(map, fn {bank, words} ->
        {bank,
         words
         |> Enum.filter(fn {word, ref} ->
           Enum.any?(Index.search(word, bank: bank, limit: 50), &same?(&1, ref))
         end)
         |> Map.new()}
      end)

    if pruned == map, do: :ok, else: write(pruned)
  end

  # ---------------------------------------------------------------------------
  # Removal
  # ---------------------------------------------------------------------------

  # The whole index went, so the source holds no takes at all. Its audio goes
  # with it ONLY when the file was recorded for that one word — see the table in
  # the moduledoc for why a voicemail is treated differently.
  defp drop_source(source, index) do
    Index.delete(source)

    audio? = one_word_recording?(index) and remove_audio(source)
    {:ok, %{index: true, audio: audio?}}
  end

  defp keep_rest(index, kept) do
    case Index.save(%{index | words: kept}) do
      :ok -> {:ok, %{index: false, audio: false}}
      {:error, _reason} = error -> error
    end
  end

  # `:manual` with exactly one word IS the shape `Capture.Take` writes for a word
  # recorded on its own. Anything else — a sentence, a voicemail, an import —
  # keeps its audio.
  defp one_word_recording?(%{origin: :manual, words: [_one]}), do: true
  defp one_word_recording?(_index), do: false

  defp remove_audio(source) do
    case SoundStudio.path_for(source) do
      nil -> false
      path -> File.rm(path) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Storage
  # ---------------------------------------------------------------------------

  defp all do
    case Settings.get(@key) do
      value when is_binary(value) -> decode(value)
      _other -> %{}
    end
  end

  defp decode(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> Map.new(map, fn {bank, words} -> {bank, refs(words)} end)
      _other -> %{}
    end
  end

  defp refs(words) when is_map(words) do
    words
    |> Enum.flat_map(fn
      {word, %{"source" => source, "start_ms" => start_ms}}
      when is_binary(source) and is_number(start_ms) ->
        [{word, %{source: source, start_ms: round_ms(start_ms)}}]

      _other ->
        []
    end)
    |> Map.new()
  end

  defp refs(_words), do: %{}

  defp put_in_map(map, bank, word, ref) do
    Map.update(map, bank, %{word => ref}, &Map.put(&1, word, ref))
  end

  defp write(map) do
    payload =
      Map.new(map, fn {bank, words} ->
        {bank,
         Map.new(words, fn {w, r} -> {w, %{"source" => r.source, "start_ms" => r.start_ms}} end)}
      end)

    case Jason.encode(payload) do
      {:ok, json} ->
        Settings.put(@key, json)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  # A take's identity is its source and its start offset, and the offset makes a
  # round trip through JSON and a DOM attribute before it comes back. Rounding
  # before comparison is what keeps 120.00000000001 the same take as 120.0.
  defp same?(_hit, nil), do: false

  defp same?(%{source: source, word: %{start_ms: start_ms}}, %{source: source} = ref),
    do: round_ms(start_ms) == ref.start_ms

  defp same?(_hit, _ref), do: false

  defp round_ms(ms), do: Float.round(ms * 1.0, @places)
end
