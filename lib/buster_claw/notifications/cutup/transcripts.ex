defmodule BusterClaw.Notifications.Cutup.Transcripts do
  @moduledoc """
  Cut-up **Phase B**: search the transcripts that already exist, and say where
  the audio lives. No recognizer, no entitlement, no new dependency.

  Every drained voicemail arrives carrying two things nobody had to build: a
  Twilio `transcript` and a locally-stored `recording_path`. That is enough to
  answer *"which of my recordings says the word 'harbor', and where is that
  audio on disk?"* — which is the question an operator actually asks first.

  ## This is discovery, not cutting

  A transcript is text **without timings**. There is no offset in this data and
  this module invents none: a `t:BusterClaw.Notifications.Cutup.Types.transcript_hit/0`
  names an event, its recording, and an excerpt, and stops there. Turning "this
  file says harbor" into "harbor starts at 4,180 ms" is Phase C's job, and
  pretending otherwise here would poison the index contract with guesses.

  ## Start with `vocabulary/1`

  Before anyone writes a speech recognizer, one question decides whether the
  whole feature is worth building: **how many candidate takes of a given word
  does this corpus actually contain?** A word you have once is a word you cannot
  use. `vocabulary/1` answers that from data already on disk, and `coverage/1`
  says how much corpus there is to begin with. Both are cheap. Run them first.

      iex> BusterClaw.Notifications.Cutup.Transcripts.coverage()
      iex> BusterClaw.Notifications.Cutup.Transcripts.top_words(limit: 40)

  ## Twilio transcription is mediocre, and the counts are a floor

  This is 8 kHz telephony audio, compressed, over a stranger's handset, and the
  transcripts in the live database show it — the callers say "Buster Claw" and
  the machine writes "busted class", "buster clark", "bus o'clock". Three
  consequences, all of which matter more than the code below:

  - **Absence of a hit is weak evidence.** The word may well be in the audio and
    simply not in the text. Never report "you have no takes of X"; report "no
    transcript contains X".
  - **`vocabulary/1`'s counts are a floor, not a census.** Real takes hide under
    misrecognitions, and the misrecognitions themselves are worth reading — a
    recurring nonsense word is usually a real word the transcriber keeps
    missing, and searching *for the nonsense* is often how you find the take.
  - **A hit is a candidate, not a confirmation.** The recording still has to be
    listened to. That is why `excerpt` exists: enough context to triage without
    opening the audio.

  ## Matching happens in Elixir, on purpose

  Whole-word matching is the whole point — searching "harbor" must not drag in
  "harbored" — and SQLite's `LIKE` cannot express a word boundary without
  contortions (`' ' || col || ' ' LIKE '% harbor %'` breaks on punctuation, on
  line ends, and on every apostrophe). So the query narrows to candidate rows in
  SQL and the precise matching runs here, over the loaded strings.

  **This is a deliberate size-bounded choice.** The transcript corpus is a
  personal phone line: hundreds of rows at most, each a few hundred characters.
  If this ever faces 100k rows, revisit it — SQLite's FTS5 with a `unicode61`
  tokenizer is the shape of the answer, and this module's public surface is
  small enough to reimplement behind.

  ## Word boundaries and apostrophes

  A word is a run of letters/digits, optionally joined by internal apostrophes:
  `o'clock` and `don't` are each **one** word. It follows that `harbor` does not
  match `harbor's` — a defensible reading of "whole word", and the one that
  keeps `vocabulary/1`'s tokens and `search/2`'s matches counting the same
  things. Pass `whole_word: false` for substring matching when you do want
  `harbor` to reach `harbored`.

  ## Paths are relative, and are never invented

  `recording_path` is returned **exactly as stored: relative to the Library
  root** (`BusterClaw.Library.Artifact.root/0`), which is the same form
  `TelephonyRecordingController` and the Studio's source picker consume. This
  module does not hand back absolute paths — resolution belongs to whoever is
  about to open the file, under its own allowlist.

  `with_recording: true` (the default) does resolve against that root, but only
  to ask `File.regular?/1`: a hit whose audio is not on the disk is nearly
  useless for a feature whose next step is cutting it up.
  """

  import Ecto.Query

  alias BusterClaw.Notifications.Cutup.Types
  alias BusterClaw.Repo
  alias BusterClaw.Telephony.Event

  # A word: letters/digits, with internal apostrophes kept ("o'clock", "don't").
  @word_pattern ~r/[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*/u

  # The character class a whole-word match may not touch on either side. Same
  # alphabet as @word_pattern, or the two would disagree about what a word is.
  @word_char "[\\p{L}\\p{N}'’]"

  # Excerpt window: characters of context taken on each side of the match, then
  # snapped outward-in to a whitespace boundary so the excerpt starts on a whole
  # word. 60 is about a line of terminal on each side — enough to judge a hit,
  # short enough that fifty of them still scan.
  @excerpt_context 60

  # Hard ceiling on a rendered excerpt, whatever the query length.
  @excerpt_limit 240

  @default_kind "voicemail"
  @default_top_words 40

  @typedoc "A word and how many times it occurs across the searched corpus."
  @type word_count :: {String.t(), pos_integer()}

  @doc """
  Find events whose transcript contains `query`, newest first.

  Matching is case-insensitive and whole-word by default. Multi-word queries are
  matched as a phrase with flexible separators, so `"call me back"` finds
  `"Call me back!"`. A query that contains no word characters at all — `""`,
  `"   "`, `"???"` — returns `[]` rather than matching everything.

  Options:

  - `:kind` — event kind to search, default `"voicemail"`. Pass `:any` for all
    kinds (SMS bodies live in `body`, not `transcript`, so in practice this
    only widens to transcribed calls).
  - `:with_recording` — default `true`: keep only events whose audio is
    **actually present on disk** under the Library root. A hit you cannot cut is
    nearly useless here. `false` searches every transcript.
  - `:since` — a `DateTime`; only events at or after it.
  - `:limit` — cap on returned hits (applied after matching, so it is a cap on
    hits and not on rows examined). Default `50`.
  - `:whole_word` — default `true`. `false` matches substrings, so `"harbor"`
    also finds `"harbored"`.

  Returns `[]` for a bad query, no candidate rows, or no matches. It never
  raises: a nil transcript is skipped, not stumbled over.
  """
  @spec search(term(), keyword()) :: [Types.transcript_hit()]
  def search(query, opts \\ []) do
    case compile_query(query, Keyword.get(opts, :whole_word, true)) do
      {:ok, regex} ->
        opts
        |> candidate_events()
        |> Enum.flat_map(&hits_for(&1, regex))
        |> apply_limit(Keyword.get(opts, :limit, 50))

      :error ->
        []
    end
  end

  @doc """
  A frequency map of every word in the corpus — **the viability check**.

  The interesting question is not "does the word 'harbor' appear" but *how many
  takes of it do I have*, because one take is a quotation and five takes are a
  cut-up. This counts occurrences (takes), not documents, across the same
  candidate set `search/2` would look at — which by default means only
  transcripts whose audio is on disk, since a word you cannot cut is not a take.

  Read it against the honesty note in the moduledoc: these counts are a **floor**.
  Twilio's transcriber drops and mangles words on telephony audio, so the real
  take count is at least this and probably more.

  Same options as `search/2` minus `:limit`/`:whole_word`, plus:

  - `:min_count` — drop words occurring fewer than this many times. Default `1`.
    `min_count: 3` is a decent first pass at "words I could actually build a
    sentence out of".

  See `top_words/1` for a sorted, readable version.
  """
  @spec vocabulary(keyword()) :: %{optional(String.t()) => pos_integer()}
  def vocabulary(opts \\ []) do
    min_count = Keyword.get(opts, :min_count, 1)

    opts
    |> candidate_events()
    |> Enum.flat_map(&words(&1.transcript))
    |> Enum.frequencies()
    |> Map.filter(fn {_word, count} -> count >= min_count end)
  end

  @doc """
  `vocabulary/1`, sorted by count descending (ties alphabetical) and truncated.

  A raw map of a few thousand words is not something a person reads; this is.
  Takes every `vocabulary/1` option plus `:limit` (default #{@default_top_words}).
  """
  @spec top_words(keyword()) :: [word_count()]
  def top_words(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_top_words)

    opts
    |> vocabulary()
    |> Enum.sort_by(fn {word, count} -> {-count, word} end)
    |> apply_limit(limit)
  end

  @doc """
  A one-glance summary of the corpus: is there enough here to bother?

  Companion to `vocabulary/1` — that one says what words you have, this one says
  how much material they came from. Both are meant to be run *before* anyone
  builds a recognizer.

  Options: `:kind` (default `"voicemail"`, `:any` for all) and `:since`.

  Returns a map:

  - `:kind` — what was counted, echoed back.
  - `:events` — rows in scope.
  - `:with_transcript` — how many carry any transcript text.
  - `:with_recording_path` — how many name a recording.
  - `:recordings_on_disk` — how many of those files actually exist under the
    Library root. The gap is the interesting number.
  - `:missing_audio` — that gap: named but not present (pruned, moved, or the
    fetch failed).
  - `:usable` — both a transcript *and* audio on disk. This is the real corpus
    size; everything else is context for it.
  - `:duration_seconds` — total audio across `:usable` events. This is Twilio's
    reported call duration, **not** measured from the files, so treat it as
    approximate.
  - `:words` / `:distinct_words` — tokens across the `:usable` transcripts.

  Never raises: an unconfigured Library root reports zero files on disk rather
  than blowing up.
  """
  @spec coverage(keyword()) :: %{
          kind: String.t() | :any,
          events: non_neg_integer(),
          with_transcript: non_neg_integer(),
          with_recording_path: non_neg_integer(),
          recordings_on_disk: non_neg_integer(),
          missing_audio: non_neg_integer(),
          usable: non_neg_integer(),
          duration_seconds: non_neg_integer(),
          words: non_neg_integer(),
          distinct_words: non_neg_integer()
        }
  def coverage(opts \\ []) do
    kind = Keyword.get(opts, :kind, @default_kind)
    root = library_root()

    events =
      Event
      |> scope_kind(kind)
      |> scope_since(opts[:since])
      |> Repo.all()

    on_disk = Enum.filter(events, &on_disk?(&1.recording_path, root))
    usable = Enum.filter(on_disk, &transcribed?/1)
    tokens = Enum.flat_map(usable, &words(&1.transcript))
    named = Enum.count(events, &is_binary(&1.recording_path))

    %{
      kind: kind,
      events: length(events),
      with_transcript: Enum.count(events, &transcribed?/1),
      with_recording_path: named,
      recordings_on_disk: length(on_disk),
      missing_audio: named - length(on_disk),
      usable: length(usable),
      duration_seconds: Enum.reduce(usable, 0, &((&1.duration_seconds || 0) + &2)),
      words: length(tokens),
      distinct_words: tokens |> Enum.uniq() |> length()
    }
  end

  @doc """
  The words of one transcript, normalized for matching (lowercased, punctuation
  stripped, internal apostrophes kept). `nil` and non-binaries yield `[]`.

  Public because it is the tokenizer `search/2` and `vocabulary/1` agree on, and
  a caller comparing this module's output to a Phase A index needs the same rule.
  """
  @spec words(term()) :: [String.t()]
  def words(text) when is_binary(text) do
    @word_pattern
    |> Regex.scan(String.downcase(text))
    |> Enum.map(&hd/1)
  end

  def words(_text), do: []

  ## Query building

  # Non-binary, empty, or punctuation-only queries are :error, which callers
  # render as "no results" rather than "everything".
  defp compile_query(query, whole_word?) when is_binary(query) do
    case words(query) do
      [] ->
        :error

      tokens ->
        # Rejoin with a flexible separator so a phrase survives whatever
        # punctuation the transcriber inserted between its words.
        body = Enum.map_join(tokens, "[^\\p{L}\\p{N}]+", &Regex.escape/1)
        compile_pattern(body, whole_word?)
    end
  end

  defp compile_query(_query, _whole_word?), do: :error

  defp compile_pattern(body, true) do
    Regex.compile("(?<!#{@word_char})" <> body <> "(?!#{@word_char})", "iu")
  end

  defp compile_pattern(body, _whole_word?), do: Regex.compile(body, "iu")

  ## Candidate rows

  defp candidate_events(opts) do
    with_recording? = Keyword.get(opts, :with_recording, true)

    Event
    |> where([e], not is_nil(e.transcript) and e.transcript != "")
    |> scope_kind(Keyword.get(opts, :kind, @default_kind))
    |> scope_since(opts[:since])
    |> scope_recording(with_recording?)
    |> order_by([e], desc: e.occurred_at, desc: e.id)
    |> Repo.all()
    |> filter_on_disk(with_recording?)
  end

  defp scope_kind(query, :any), do: query
  defp scope_kind(query, nil), do: query
  defp scope_kind(query, kind), do: where(query, [e], e.kind == ^kind)

  defp scope_since(query, %DateTime{} = since), do: where(query, [e], e.occurred_at >= ^since)
  defp scope_since(query, _since), do: query

  # The cheap half of the recording filter: SQL drops the rows with no path at
  # all, Elixir then checks the disk for the rest.
  defp scope_recording(query, true), do: where(query, [e], not is_nil(e.recording_path))
  defp scope_recording(query, _with_recording?), do: query

  defp filter_on_disk(events, true) do
    root = library_root()
    Enum.filter(events, &on_disk?(&1.recording_path, root))
  end

  defp filter_on_disk(events, _with_recording?), do: events

  defp on_disk?(path, root) when is_binary(path) and is_binary(root) do
    File.regular?(Path.join(root, path))
  end

  defp on_disk?(_path, _root), do: false

  # Read straight from the env rather than through `Artifact.root/0`, which
  # raises when unset. Nothing in this module may raise, so an unconfigured root
  # simply means "no audio is on disk".
  defp library_root, do: Application.get_env(:buster_claw, :library_root)

  defp transcribed?(%Event{transcript: transcript}),
    do: is_binary(transcript) and String.trim(transcript) != ""

  ## Hits

  defp hits_for(%Event{transcript: transcript} = event, regex) when is_binary(transcript) do
    case Regex.run(regex, transcript, return: :index) do
      [{start, match_bytes} | _rest] ->
        [
          %{
            event_id: event.id,
            recording_path: event.recording_path,
            occurred_at: event.occurred_at,
            from_number: event.from_number,
            excerpt: excerpt(transcript, start, match_bytes),
            match_count: length(Regex.scan(regex, transcript))
          }
        ]

      nil ->
        []
    end
  end

  defp hits_for(_event, _regex), do: []

  # `Regex.run/3` returns *byte* offsets, and a match always lands on codepoint
  # boundaries, so these three slices are each valid UTF-8. Everything after
  # that is character work.
  defp excerpt(transcript, start, match_bytes) do
    tail_start = start + match_bytes

    before_text = binary_part(transcript, 0, start)
    match = binary_part(transcript, start, match_bytes)
    after_text = binary_part(transcript, tail_start, byte_size(transcript) - tail_start)

    [lead(before_text), match, trail(after_text)]
    |> IO.iodata_to_binary()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate()
  end

  defp lead(text) do
    total = String.length(text)

    if total <= @excerpt_context do
      text
    else
      tail = String.slice(text, (total - @excerpt_context)..-1//1)
      # Drop the partial word the slice landed inside, so the excerpt opens on a
      # whole word.
      case String.split(tail, ~r/\s/u, parts: 2) do
        [_partial, rest] -> "…" <> rest
        [_only] -> "…" <> tail
      end
    end
  end

  defp trail(text) do
    if String.length(text) <= @excerpt_context do
      text
    else
      head = String.slice(text, 0, @excerpt_context)

      case Regex.run(~r/^(.*)\s\S*$/us, head, capture: :all_but_first) do
        [rest] -> rest <> "…"
        _no_space -> head <> "…"
      end
    end
  end

  defp truncate(text) do
    if String.length(text) > @excerpt_limit do
      String.slice(text, 0, @excerpt_limit) <> "…"
    else
      text
    end
  end

  defp apply_limit(list, limit) when is_integer(limit) and limit >= 0, do: Enum.take(list, limit)
  defp apply_limit(list, _limit), do: list
end
