defmodule BusterClaw.Notifications.Cutup.Index do
  @moduledoc """
  Persistence and search for word indexes — the half of the cut-up pipeline that
  answers *"which file says 'harbor', and exactly when?"* (STUDIO_ROADMAP Part
  III, Phase A).

  `Cutup.Types` defines the shape; this module is the only thing that writes it
  to disk, reads it back, and looks things up in it. It holds no audio and calls
  no DSP: an index is text and numbers, and keeping it that way is what lets the
  search half be exercised long before a recognizer exists.

  ## Where indexes live

      <workspace>/sounds/studio/          # the sources, SoundStudio.dir/0
      <workspace>/sounds/studio/index/    # one <source><ext>.index.json per source

  Alongside the sources, not inside a hidden folder, because these are
  hand-editable by design — correcting a recognizer's mis-hearing is a text edit,
  and an operator who can find the file can make the cut-up work. The filename
  carries the **full source basename including its audio extension**
  (`voicemail-03.wav.index.json`), so `voicemail-03.wav` and `voicemail-03.mp3`
  index separately instead of silently sharing one file.

  `SoundStudio.list/0` only reports regular files with audio extensions, so this
  directory never appears as an importable clip — the same trick `mixes/`
  already relies on.

  ## A source is a basename, and that is a security boundary

  Every entry point runs its `source` through the same gate: no `/`, no `\\`, no
  `..`, no null byte, nothing that `Path.basename/1` would shorten. Then the name
  must survive `BusterClaw.AudioName.safe_name/1` unchanged (compared
  case-insensitively, so a real `VOICE.WAV` is not refused for the extension-case
  rewrite that sanitizer performs). An index therefore **cannot name a file
  outside the studio's sources directory**, whether it arrived from a recognizer,
  a hand-edited JSON file, or a CLI argument. This is checked at `build/3`,
  `save/1`, `load/1`, `delete/1` and on the `:source` search option — not once at
  the edge, because there is no single edge.

  ## Normalization happens on the way IN

  `word` is stored already lowercased and stripped of punctuation; `text` keeps
  what was actually recognized. Search normalizes only the *query*, never the
  corpus, so the cost of a lookup is a comparison per word rather than a regex
  per word. `save/1` re-runs the normalizer before writing, so a hand-edited file
  is canonical again the next time it is saved.

  What the normalizer does **not** do, said plainly: no accent folding (`café`
  and `cafe` are different words), no stemming (`walk` does not find `walked`),
  and inner punctuation is dropped rather than split — `well-known` becomes one
  token `wellknown`, which the two-word query `well known` will not find. These
  are limits worth knowing before blaming the recognizer.

  ## Phrase search, and what "consecutive" means

  A multi-word query matches **adjacent entries in one source's word list**, and
  returns them as a single synthesized `t:BusterClaw.Notifications.Cutup.Types.hit/0`
  spanning the whole phrase: `start_ms` from the first word, `end_ms` from the
  last, `text` the recognized words joined by spaces, and `confidence` the
  **minimum** of the members'. Minimum rather than mean because a phrase is only
  as good as its worst word, and averaging lets one piece of garbage hide behind
  four good ones.

  Adjacent in the *list* is not the same as adjacent in *time*: a recognizer
  emits no entry for silence, so "call me back" still matches across a two-second
  pause. For splicing that is usually what you want — the assembler cuts each
  word and rejoins them anyway — but it means a phrase hit is not proof the
  speaker said it in one breath. There is deliberately no maximum-gap option yet;
  add one when a real corpus shows it is needed.

  ## No cache, on purpose

  `search/2` and `words_available/1` read every index file on every call. For the
  hundreds of sources a workspace realistically holds that is milliseconds, and
  the alternative — a cache over files the operator is invited to hand-edit — is
  a class of bug where the search disagrees with the file and nobody can tell
  why. Decision 9 says an index is never silently recomputed; it says nothing
  about re-reading one.

  ## Totality

  Nothing here raises. A corrupt file, a missing directory, a malformed word
  entry, a non-binary query: each has a named result. The one deviation from a
  uniform `{:ok, _} | {:error, _}` is `search/2` and `words_available/1`, which
  return a list and a map — they have no error channel by construction, so a
  query they cannot use finds nothing rather than failing.
  """

  alias BusterClaw.AudioName
  alias BusterClaw.Library.Artifact
  alias BusterClaw.Notifications.Cutup.Types

  @subdir Path.join(["sounds", "studio", "index"])
  @ext ".index.json"

  @origins [:manual, :aligned, :recognizer, :imported]

  # Everything that is not a letter or a digit, in any script. See the moduledoc
  # for what this deliberately does not handle.
  @strip ~r/[^\p{L}\p{N}]+/u

  @typedoc "A source basename inside the studio's sources directory."
  @type source :: String.t()

  @typedoc "How `build/3` labels and stamps the index it constructs."
  @type build_opts :: [
          origin: :manual | :aligned | :recognizer | :imported,
          language: String.t() | nil,
          indexed_at: DateTime.t() | nil
        ]

  @typedoc """
  Narrowing options shared by `search/2` and `words_available/1`.

  `:min_confidence` is a floor, not a threshold with meaning — see
  `t:BusterClaw.Notifications.Cutup.Types.word/0` on why confidence ranks rather
  than measures. `:limit` applies after sorting, so it keeps the *best* hits.
  """
  @type search_opts :: [
          source: String.t(),
          min_confidence: number(),
          limit: pos_integer()
        ]

  @typedoc "Why a call was refused. Every one of these is returned, never raised."
  @type error ::
          :invalid_source
          | :unsafe_source
          | :invalid_origin
          | :invalid_index
          | :not_found
          | :invalid
          | :file.posix()

  # ---------------------------------------------------------------------------
  # Location
  # ---------------------------------------------------------------------------

  @doc "Absolute path to `<workspace>/sounds/studio/index/`."
  @spec dir() :: String.t()
  def dir, do: Artifact.workspace_path(@subdir)

  # ---------------------------------------------------------------------------
  # Building
  # ---------------------------------------------------------------------------

  @doc """
  Construct an index from a loose word list, normalizing and validating as it
  goes, so no caller has to hand-build the map.

  Entries may use atom or string keys and may carry `text`, `word`, or both:
  a recognizer supplies `text` and the normalized form is derived; a fixture may
  supply only `word`. **Unusable entries are dropped, not fatal** — a recognizer
  that emits one junk segment should not lose the other four hundred. An entry is
  unusable when it is not a map, has no usable text, normalizes to nothing (pure
  punctuation is not a word you can search for), lacks numeric bounds, or has
  `end_ms <= start_ms` (a zero-length cut is silence). Compare
  `length(index.words)` against what you passed in to detect drops.

  A missing `confidence` is read as `1.0`, because a hand-authored index has no
  reason to carry one and treating absence as zero would make every fixture
  invisible to a `:min_confidence` filter.

  Words are sorted by `start_ms`. That ordering is not cosmetic: phrase search
  defines "consecutive" as adjacency in this list.
  """
  @spec build(source(), [map()], build_opts()) :: {:ok, Types.index()} | {:error, error()}
  def build(source, words, opts \\ [])

  def build(source, words, opts) when is_list(words) and is_list(opts) do
    with {:ok, name} <- safe_source(source),
         {:ok, origin} <- origin(Keyword.get(opts, :origin, :manual)) do
      {:ok,
       %{
         source: name,
         words: normalize_words(words),
         origin: origin,
         language: language(Keyword.get(opts, :language)),
         indexed_at: stamp(Keyword.get(opts, :indexed_at, :now))
       }}
    end
  end

  def build(_source, _words, _opts), do: {:error, :invalid_index}

  @doc """
  The matching form of a word: lowercased, every non-alphanumeric removed.

  Public because the query side and the corpus side must use the same function
  or they will drift, and because a caller composing its own filter needs it.
  Anything that is not a binary normalizes to `""`.
  """
  @spec normalize_word(term()) :: String.t()
  def normalize_word(term) when is_binary(term) do
    term |> String.downcase() |> String.replace(@strip, "")
  end

  def normalize_word(_term), do: ""

  # ---------------------------------------------------------------------------
  # Storage
  # ---------------------------------------------------------------------------

  @doc """
  Write an index to `sounds/studio/index/`, creating the directory if absent.

  The index is re-normalized on the way through, so what lands on disk is always
  canonical — sorted, with `word` derived from `word` or `text` — even if the
  caller assembled the map by hand or hand-edited the previous file.
  """
  @spec save(Types.index()) :: :ok | {:error, error()}
  def save(%{source: source} = index) do
    with {:ok, name} <- safe_source(source),
         {:ok, json} <- encode(name, index),
         :ok <- File.mkdir_p(dir()) do
      File.write(path_for(name), json)
    end
  end

  def save(_index), do: {:error, :invalid_index}

  @doc """
  Read the index for a source basename.

  `:not_found` means no file; `:invalid` means there is a file and it is not an
  index — unparseable JSON, or JSON that carries no `"words"` list. Corrupt is
  distinguished from absent because they call for different fixes: one is
  "transcribe it", the other is "look at what you edited".

  **The filename wins over the `"source"` inside the file.** The name you loaded
  by is the addressable identity; a disagreement means the file was copied, and
  trusting its contents would produce an index that names a different source than
  the one that was asked for.
  """
  @spec load(source()) :: {:ok, Types.index()} | {:error, error()}
  def load(source) when is_binary(source) do
    with {:ok, name} <- safe_source(source),
         {:ok, body} <- read(name),
         {:ok, decoded} <- decode(body) do
      from_map(name, decoded)
    end
  end

  def load(_source), do: {:error, :invalid_source}

  @doc "Source basenames that have an index, sorted. Never raises; `[]` if the directory is absent."
  @spec list() :: [source()]
  def list do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, @ext))
        |> Enum.map(&String.replace_suffix(&1, @ext, ""))
        |> Enum.filter(&match?({:ok, _name}, safe_source(&1)))
        |> Enum.sort_by(&String.downcase/1)

      {:error, _reason} ->
        []
    end
  end

  @doc "Whether a source has an index."
  @spec indexed?(term()) :: boolean()
  def indexed?(source) when is_binary(source), do: source in list()
  def indexed?(_source), do: false

  @doc "Delete a source's index. The audio it described is untouched."
  @spec delete(source()) :: :ok | {:error, error()}
  def delete(source) when is_binary(source) do
    case safe_source(source) do
      {:ok, name} -> remove(path_for(name))
      {:error, _reason} = error -> error
    end
  end

  def delete(_source), do: {:error, :invalid_source}

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Search
  # ---------------------------------------------------------------------------

  @doc """
  Find a word or a phrase across every index, best take first.

  Single words and multi-word phrases go down the same path: a phrase is a
  window of N consecutive words, and a single word is a window of one. See the
  moduledoc for what "consecutive" means and how a phrase's confidence is
  computed.

  Results are sorted by confidence descending — the point of the whole feature is
  that the *best* take of a word is the one you splice — then by source and start
  time so the order is stable enough to test and to page through.

  Returns `[]` rather than an error for a query that cannot be used (not a
  binary, or nothing but punctuation): the signature has no error channel, and a
  search that finds nothing is the truthful answer to "find me `,,,`".
  """
  @spec search(term(), search_opts()) :: [Types.hit()]
  def search(query, opts \\ [])

  def search(query, opts) when is_binary(query) and is_list(opts) do
    case tokens(query) do
      [] ->
        []

      tokens ->
        floor = min_confidence(opts)

        opts
        |> indexes()
        |> Enum.flat_map(&hits(&1, tokens))
        |> Enum.filter(&(&1.word.confidence >= floor))
        |> Enum.sort_by(&{-&1.word.confidence, &1.source, &1.word.start_ms})
        |> cap(limit(opts))
    end
  end

  def search(_query, _opts), do: []

  @doc """
  Every indexed word and how many takes of it exist across the corpus.

  **This is the question that decides whether a cut-up is possible at all.**
  Before assembling a sentence you need to know that the words in it exist; this
  is the map that says so, and a word absent from it can only be spliced from
  something not yet indexed. Accepts the same `:source` and `:min_confidence`
  narrowing as `search/2` (`:limit` does not apply).
  """
  @spec words_available(search_opts()) :: %{String.t() => non_neg_integer()}
  def words_available(opts \\ [])

  def words_available(opts) when is_list(opts) do
    floor = min_confidence(opts)

    opts
    |> indexes()
    |> Enum.flat_map(& &1.words)
    |> Enum.filter(&(&1.confidence >= floor))
    |> Enum.frequencies_by(& &1.word)
  end

  def words_available(_opts), do: %{}

  @doc """
  How many takes of one word (or phrase) exist — `words_available/1` for a single
  question, and the cheapest way to ask "can I even say this?".
  """
  @spec takes(term(), search_opts()) :: non_neg_integer()
  def takes(query, opts \\ []), do: query |> search(opts) |> length()

  # Load every index in scope. A `:source` that is unreadable or unsafe narrows
  # to nothing, which is the same answer as "that source has no index".
  defp indexes(opts) do
    case Keyword.get(opts, :source) do
      nil -> Enum.flat_map(list(), &loaded/1)
      source -> loaded(source)
    end
  end

  defp loaded(source) do
    case load(source) do
      {:ok, index} -> [index]
      {:error, _reason} -> []
    end
  end

  # Windows of N consecutive words whose normalized forms are exactly the query.
  defp hits(%{source: source, words: words}, tokens) do
    size = length(tokens)

    words
    |> Enum.chunk_every(size, 1, :discard)
    |> Enum.filter(fn run -> Enum.map(run, & &1.word) == tokens end)
    |> Enum.map(&%{source: source, word: joined(&1)})
  end

  defp joined([word]), do: word

  defp joined(run) do
    first = List.first(run)
    last = List.last(run)

    %{
      word: Enum.map_join(run, " ", & &1.word),
      text: Enum.map_join(run, " ", & &1.text),
      start_ms: first.start_ms,
      end_ms: last.end_ms,
      confidence: run |> Enum.map(& &1.confidence) |> Enum.min()
    }
  end

  defp tokens(query) do
    query
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(&normalize_word/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp min_confidence(opts) do
    case Keyword.get(opts, :min_confidence) do
      value when is_number(value) -> value * 1.0
      _other -> 0.0
    end
  end

  defp limit(opts) do
    case Keyword.get(opts, :limit) do
      value when is_integer(value) and value > 0 -> value
      _other -> nil
    end
  end

  defp cap(hits, nil), do: hits
  defp cap(hits, limit), do: Enum.take(hits, limit)

  # ---------------------------------------------------------------------------
  # The source gate. Every public entry point goes through this.
  # ---------------------------------------------------------------------------

  defp safe_source(source) when is_binary(source) do
    cond do
      source in ["", ".", ".."] -> {:error, :invalid_source}
      String.contains?(source, ["/", "\\", "..", <<0>>]) -> {:error, :invalid_source}
      Path.basename(source) != source -> {:error, :invalid_source}
      not fixpoint?(source) -> {:error, :unsafe_source}
      true -> {:ok, source}
    end
  end

  defp safe_source(_source), do: {:error, :invalid_source}

  # Compared case-insensitively because `safe_name/1` downcases the extension it
  # re-attaches, so a genuine `VOICE.WAV` would otherwise be refused for a
  # difference that is not a safety difference.
  defp fixpoint?(source) do
    String.downcase(AudioName.safe_name(source)) == String.downcase(source)
  end

  defp path_for(name), do: Path.join(dir(), name <> @ext)

  # ---------------------------------------------------------------------------
  # Normalizing a word list
  # ---------------------------------------------------------------------------

  defp normalize_words(words) do
    words
    |> Enum.map(&to_word/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.start_ms)
  end

  defp to_word(entry) when is_map(entry) do
    raw = pick(entry, :word)
    text = pick(entry, :text)
    display = if is_binary(text) and text != "", do: text, else: raw
    matchable = if is_binary(raw) and raw != "", do: raw, else: display

    build_word(
      normalize_word(matchable),
      display,
      number(pick(entry, :start_ms)),
      number(pick(entry, :end_ms)),
      number(pick(entry, :confidence))
    )
  end

  defp to_word(_entry), do: nil

  defp build_word(normalized, display, start_ms, end_ms, confidence) do
    if normalized == "" or not is_binary(display) or is_nil(start_ms) or is_nil(end_ms) or
         start_ms < 0 or end_ms <= start_ms do
      nil
    else
      %{
        word: normalized,
        text: display,
        start_ms: start_ms,
        end_ms: end_ms,
        confidence: clamp(confidence)
      }
    end
  end

  # Atom keys and string keys both, so a decoded JSON map and a hand-written
  # fixture go through one path instead of two that can disagree.
  defp pick(entry, key), do: Map.get(entry, key, Map.get(entry, Atom.to_string(key)))

  defp number(value) when is_number(value), do: value * 1.0
  defp number(_value), do: nil

  defp clamp(nil), do: 1.0
  defp clamp(value), do: value |> max(0.0) |> min(1.0)

  defp origin(value) when value in @origins, do: {:ok, value}

  defp origin(value) when is_binary(value) do
    case Enum.find(@origins, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_origin}
      found -> {:ok, found}
    end
  end

  defp origin(_value), do: {:error, :invalid_origin}

  defp language(value) when is_binary(value), do: value
  defp language(_value), do: nil

  defp stamp(:now), do: DateTime.utc_now()
  defp stamp(%DateTime{} = at), do: at
  defp stamp(_other), do: nil

  # ---------------------------------------------------------------------------
  # JSON
  # ---------------------------------------------------------------------------

  defp encode(name, index) do
    map = %{
      "version" => 1,
      "source" => name,
      "origin" => index |> Map.get(:origin) |> encodable_origin(),
      "language" => index |> Map.get(:language) |> language(),
      "indexed_at" => index |> Map.get(:indexed_at) |> encodable_time(),
      "words" =>
        index
        |> Map.get(:words, [])
        |> List.wrap()
        |> normalize_words()
        |> Enum.map(fn word ->
          %{
            "word" => word.word,
            "text" => word.text,
            "start_ms" => word.start_ms,
            "end_ms" => word.end_ms,
            "confidence" => word.confidence
          }
        end)
    }

    case Jason.encode(map, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, :invalid_index}
    end
  end

  defp encodable_origin(value) do
    case origin(value) do
      {:ok, found} -> Atom.to_string(found)
      {:error, _reason} -> "manual"
    end
  end

  defp encodable_time(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp encodable_time(_other), do: nil

  defp read(name) do
    case File.read(path_for(name)) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  # Tolerant about everything except the one thing that makes a file an index:
  # a list of words. A bad `origin` or an unparseable timestamp is a degraded
  # field, not a file you cannot open.
  defp from_map(name, %{"words" => words} = map) when is_list(words) do
    {:ok,
     %{
       source: name,
       words: normalize_words(words),
       origin: decoded_origin(map),
       language: language(Map.get(map, "language")),
       indexed_at: decoded_time(Map.get(map, "indexed_at"))
     }}
  end

  defp from_map(_name, _decoded), do: {:error, :invalid}

  defp decoded_origin(map) do
    case origin(Map.get(map, "origin")) do
      {:ok, found} -> found
      {:error, _reason} -> :manual
    end
  end

  defp decoded_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  defp decoded_time(_value), do: nil
end
