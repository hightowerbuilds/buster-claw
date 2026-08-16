defmodule BusterClaw.Commands.Sound do
  @moduledoc """
  The `sound_*` command surface — the Studio, addressable (STUDIO_ROADMAP Part I
  Phases 0/1 and Part III Phase A/B). Delegated to from `BusterClaw.Commands`.

  The Sound Studio is the one authoring surface in this app the agent cannot
  reach. The library verbs give it eyes and nothing else: `sound_list`,
  `sound_routes`, `sound_sources` and `sound_probe` are `:safe`, read files they
  never open for writing, and touch no setting.

  The cut-up verbs are the other half — finding words inside recordings and
  splicing them back into ramshackle sentences. They fall into two families that
  are easy to confuse and must not be:

  - **Transcripts** (`sound_transcript_*`, `sound_corpus`) — Twilio's text for
    each voicemail. **No timings**, so this is discovery: which recording says
    the word, and is its audio even on disk. Nothing here can be cut.
  - **The index** (`sound_index_*`) — words *with* start/end times, which is
    what a cut needs. An index hit is already a cut: hand its `source`,
    `start_ms` and `end_ms` straight to `sound_assemble`.

  `sound_find` is the only verb here where a **matcher** produces timings.
  `sound_align` guesses proportionally from a transcript; `sound_find` takes one
  confirmed instance of a word and finds the others across the corpus by
  acoustic similarity — MFCC features, subsequence DTW, no transcription and no
  network — writing what it finds back as `origin: :recognizer`. It is a
  shortlist generator rather than an oracle, and it is priced accordingly: a
  source whose features are not cached costs about 109 seconds to analyse and
  about 155 ms once warm, so which sources were cold is always reported and
  `warm_only: true` searches the cached set alone rather than blocking for
  minutes.

  `sound_sentence` is the whole cut-up in one call — a phrase in, an assembled
  clip out — and it is the only verb that *chooses* between takes: it tokenises
  through `Index.normalize_word/1`, searches the index per word, builds a
  candidate lattice and hands it to `Cutup.Select`'s Viterbi search before
  `Assemble` splices the winner. Two of its answers matter as much as the audio:
  the words it could **not** find, which are fatal unless `allow_missing: true`,
  and whether the lattice had anything to decide at all — `candidates == slots`
  means every word had exactly one take and the search chose nothing.

  `sound_align` is the bridge between the two families, and the reason the index
  family is reachable at all: it fits a transcript — text with no timings — onto
  the spans of activity `Cutup.Vad` finds in the audio, and saves the result as
  an index. **Nothing in this module recognizes speech.** The timings it
  produces are approximate by construction and are expected to be improved
  later, word by word — so the verb reports two things a caller can judge them
  by without listening: a confidence spread, which is a plausibility check on
  the recording as a whole and *not* a per-word verdict, and `unplaced_ms`, the
  detected speech no word ended up covering.

  `sound_import`, `sound_assemble` and the four editing verbs (`sound_trim`,
  `sound_fade`, `sound_normalize`, `sound_concat`) are the verbs here that write
  audio, and every one of them writes a new *source* — none routes anything,
  which is why they are `:restricted` but not gated. Routing is the only act
  that changes what the machine does unattended.

  ## The one gated verb

  `sound_apply` is the end of the walk and the only gated entry: it copies a
  studio source into the sound library and points a routing key at it, which is
  the difference between "the agent made me a sound" and "the agent changed what
  my computer does at 3am". Two refusals happen *before* anything is written —
  a key that is not in `Sound.route_keys/0`, so a typo cannot be discovered
  later as a chime that does not play, and a library name that is already taken
  or that would shadow a bundled default, because this layer overrides the
  bundled set by basename and `alarm.wav` installed here replaces the built-in
  alarm for every key that falls back to it, not only the one being routed.

  `sound_restore_defaults` is the way back, and it exists because an agent that
  has just overwritten a chime is exactly who needs one. It copies the bundled
  set into the workspace without ever overwriting, and — only when asked — clears
  the routing map so every key inherits again.

  ## The editing verbs all render to a new name

  `sound_trim`, `sound_fade`, `sound_normalize` and `sound_concat` each wrap one
  pure function in `SoundStudio` and write the result as a **new** source; an
  existing name is refused as `:name_taken` unless `overwrite: true`. Editing in
  place would destroy a voicemail that cannot be re-recorded, and a render to a
  new file is reviewable in a way an in-place mutation is not.

  Each returns the new name together with `duration_ms` and `peak`, beside the
  source's own — the agent cannot hear, so those two numbers are the whole of
  how it checks that a cut cut something and that a level moved.

  ## The one verb that names a file outside the sound stores

  Every other verb here takes a **basename** and resolves it against a directory
  listing, so nothing outside `sounds/` is even expressible. `sound_import` has
  to reach further — a voicemail lives under the Library root, in none of the
  three sound stores — and `sound_probe` follows it there so the workflow is
  *probe it, then import it* rather than *import blind, then probe*.

  That reach is deliberately the narrowest thing that works: an `event_id`,
  whose `recording_path` the app stored itself, or a path **relative to the
  Library root**. `under_library/1` is the whole boundary — absolute paths, `..`
  and null bytes are refused before the filesystem is touched, and the expanded
  result is re-checked against the root. There is no second line of defence
  behind it: a verb that accepted an absolute path would let an agent read
  anything this app can read.

  Two things the shape of these answers is deliberately built around:

  **The library has two layers and the workspace wins.** `sounds/` overrides the
  bundled defaults *by basename* (`Sound.resolve_path/1`), so a listing that
  showed one flat set of names is how "I replaced the chime and nothing changed"
  becomes a bug report. `sound_list` therefore reports every name once, with the
  layer it resolves from and whether a bundled default is being shadowed.

  **The agent cannot hear.** `sound_probe` is its whole substitute for ears:
  format, duration, peak, and whether the file is already in the Studio's
  internal PCM16/mono/22.05 kHz format — the one fact that decides whether an
  edit needs the system decoder at all.

  Peak is the fact that needs *samples*, and an mp3 has none until something
  decodes it — so the default probe of a voicemail is blind on exactly the file
  the acceptance walk starts from. `decode: true` fixes that by running the file
  through `import_source/1` and measuring the clip that comes back. It is opt-in
  because it is a subprocess and a full decode; the header-only path stays the
  default and stays honest about what it could not answer.

  Names are basenames, never paths. Resolution goes through `Sound.path_for/1`,
  `Sound.bundled_path_for/1` and `SoundStudio.path_for/1`, each of which
  allowlists against a real directory listing, and anything carrying a separator
  is refused as `:invalid_name` before it gets that far.
  """

  alias BusterClaw.AudioName
  alias BusterClaw.Notifications.Cutup.Align
  alias BusterClaw.Notifications.Cutup.Assemble
  alias BusterClaw.Notifications.Cutup.Dtw
  alias BusterClaw.Notifications.Cutup.Features
  alias BusterClaw.Notifications.Cutup.Index
  alias BusterClaw.Notifications.Cutup.Sentence
  alias BusterClaw.Notifications.Cutup.Signal
  alias BusterClaw.Notifications.Cutup.Transcripts
  alias BusterClaw.Notifications.Cutup.Vad
  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Telephony

  @workspace "workspace"
  @bundled "bundled"
  @studio "studio"
  @library "library"

  @default_transcript_limit 50
  @default_word_limit 50
  @origins ~w(manual aligned recognizer imported)

  # The same-speaker operating point measured over 990 labelled pairs
  # (STUDIO_ROADMAP Part III, "The threshold, measured against real speech"):
  # precision 0.88, recall 0.93. It is a starting point to re-measure against a
  # real corpus, never a constant.
  @default_find_threshold 6.0
  @default_find_limit 10

  # Takes per word offered to the lattice. Twenty is far more than the corpus
  # usually holds and the search is cheap in the number of candidates; the
  # expensive term is `Select`'s own capped sibling DTW.
  @default_takes 20

  # The anchors of the distance -> confidence map. See `confidence_of/1`.
  @best_distance 3.0
  @worst_distance 12.0
  @best_confidence 0.9
  @worst_confidence 0.1

  # ---------------------------------------------------------------------------
  # The library, both layers
  # ---------------------------------------------------------------------------

  def sound_list(_args \\ %{}) do
    workspace = Sound.list()
    bundled = Sound.bundled_list()

    in_workspace = MapSet.new(workspace)
    in_bundled = MapSet.new(bundled)

    sounds =
      (workspace ++ bundled)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&library_entry(&1, in_workspace, in_bundled))

    {:ok,
     %{
       enabled: Sound.enabled?(),
       workspace_dir: Sound.dir(),
       bundled_dir: Sound.bundled_dir(),
       counts: %{
         total: length(sounds),
         workspace: length(workspace),
         bundled: length(bundled)
       },
       shadowed: sounds |> Enum.filter(& &1.shadowing) |> Enum.map(& &1.name),
       sounds: sounds
     }}
  end

  # `layer` is the layer that WINS — the file that actually plays for this name.
  # `shadowing` says the workspace copy is hiding a bundled default of the same
  # name, which is the fact a person is missing when they say they replaced a
  # chime and nothing changed.
  defp library_entry(name, in_workspace, in_bundled) do
    workspace? = MapSet.member?(in_workspace, name)
    bundled? = MapSet.member?(in_bundled, name)

    %{
      name: name,
      layer: if(workspace?, do: @workspace, else: @bundled),
      in_workspace: workspace?,
      in_bundled: bundled?,
      shadowing: workspace? and bundled?,
      path: Sound.resolve_path(name)
    }
  end

  # ---------------------------------------------------------------------------
  # The routing table
  # ---------------------------------------------------------------------------

  def sound_routes(_args \\ %{}) do
    map = Sound.sound_map()
    routes = Enum.map(route_keys_in_display_order(), &route(&1, map))

    {:ok,
     %{
       enabled: Sound.enabled?(),
       silent_value: Sound.silent(),
       counts: %{
         keys: length(routes),
         assigned: Enum.count(routes, &(&1.assigned != nil)),
         silent: Enum.count(routes, &(&1.origin == "silent")),
         nothing: Enum.count(routes, &(&1.plays == nil))
       },
       routes: routes
     }}
  end

  # Display order comes from `route_options/0` (the order a person meets these
  # in Settings), but every key from `route_keys/0` must appear — a key with no
  # label would otherwise be invisible here and still be routable.
  defp route_keys_in_display_order do
    labelled = Enum.map(Sound.route_options(), fn {_label, key} -> key end)
    labelled ++ (Sound.route_keys() -- labelled)
  end

  defp route(key, map) do
    assigned = Map.get(map, key)
    inherited = if key != "default", do: Map.get(map, "default")
    plays = Sound.resolved(key)

    %{
      key: key,
      label: Sound.route_label(key),
      assigned: assigned,
      plays: plays,
      plays_layer: layer_of(plays),
      origin: origin(assigned, inherited, plays)
    }
  end

  # How this key got its answer, which is what an agent needs before proposing a
  # change: an explicit entry is the operator's choice, an inherited one belongs
  # to "default", and a fallback belongs to the bundled set (or the legacy
  # first-file rule) and has no map entry at all.
  defp origin(assigned, inherited, plays) do
    silent = Sound.silent()

    cond do
      assigned == silent -> "silent"
      is_binary(assigned) -> "explicit"
      inherited == silent -> "silent"
      is_binary(inherited) -> "inherited"
      is_binary(plays) -> "fallback"
      true -> "none"
    end
  end

  defp layer_of(nil), do: nil

  defp layer_of(name) do
    cond do
      Sound.path_for(name) -> @workspace
      Sound.bundled_path_for(name) -> @bundled
      true -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # The Studio's imported clips
  # ---------------------------------------------------------------------------

  def sound_sources(_args \\ %{}) do
    dir = SoundStudio.dir()

    sources =
      Enum.map(SoundStudio.list(), fn name ->
        path = Path.join(dir, name)
        %{name: name, path: path, bytes: byte_size_of(path)}
      end)

    {:ok,
     %{
       dir: dir,
       count: length(sources),
       # Reported rather than assumed: without the system decoder, only WAV
       # already in the internal format can ever be imported here.
       decoder_available: SoundStudio.decoder_available?(),
       internal_format: internal_format(),
       sources: sources
     }}
  end

  # ---------------------------------------------------------------------------
  # One sound, described — the substitute for ears
  # ---------------------------------------------------------------------------

  def sound_probe(args) when is_map(args) do
    with {:ok, target} <- probe_target(args) do
      {:ok, describe(target, boolean(Map.get(args, "decode"), false))}
    end
  end

  def sound_probe(_args), do: {:error, :missing_name}

  # Three ways to name one file, in precedence order. `event_id` and `path`
  # reach the Library root through the same funnel `sound_import` uses — the
  # point being that a voicemail can be *looked at* before it is brought in,
  # rather than imported blind and probed afterwards.
  defp probe_target(args) do
    cond do
      present?(args, "event_id") or present?(args, "path") ->
        with {:ok, origin} <- import_origin(args) do
          {:ok,
           %{
             name: Path.basename(origin.path),
             layer: @library,
             path: origin.path,
             event_id: origin.event_id,
             library_path: origin.relative
           }}
        end

      is_binary(Map.get(args, "name")) ->
        with {:ok, clean} <- validate_name(Map.get(args, "name")),
             {:ok, layer, path} <- locate(clean) do
          {:ok, %{name: clean, layer: layer, path: path, event_id: nil, library_path: nil}}
        end

      true ->
        {:error, :missing_name}
    end
  end

  defp present?(args, key), do: not is_nil(Map.get(args, key)) and Map.get(args, key) != ""

  # A name is a basename or it is nothing. `path_for/1` already allowlists
  # against a directory listing, so traversal could never resolve — but a
  # traversal attempt deserves its own named refusal rather than an ambiguous
  # "not found".
  defp validate_name(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> {:error, :invalid_name}
      trimmed in [".", ".."] -> {:error, :invalid_name}
      String.contains?(trimmed, ["/", "\\", <<0>>]) -> {:error, :invalid_name}
      Path.basename(trimmed) != trimmed -> {:error, :invalid_name}
      true -> {:ok, trimmed}
    end
  end

  # Workspace library, then the bundled default it would shadow, then the
  # studio's raw sources — the same precedence the player uses, extended to the
  # one store the player never reads.
  defp locate(name) do
    case {Sound.path_for(name), Sound.bundled_path_for(name), SoundStudio.path_for(name)} do
      {path, _bundled, _studio} when is_binary(path) -> {:ok, @workspace, path}
      {_workspace, path, _studio} when is_binary(path) -> {:ok, @bundled, path}
      {_workspace, _bundled, path} when is_binary(path) -> {:ok, @studio, path}
      _none -> {:error, :not_found}
    end
  end

  defp describe(target, decode?) do
    path = target.path
    header = header_facts(path)
    clip = clip_facts(path)
    decoded = decoded_facts(clip, path, decode?)
    decoder? = SoundStudio.decoder_available?()

    %{
      name: target.name,
      layer: target.layer,
      path: path,
      event_id: target.event_id,
      library_path: target.library_path,
      bytes: byte_size_of(path),
      # A parsed clip is exact; a decode is exact too and the only way to reach
      # a compressed file's samples; the header prober is the last fallback.
      duration_ms: clip[:duration_ms] || decoded[:duration_ms] || header[:duration_ms],
      # Deliberately NOT taken from the decode: the decoder resamples and
      # downmixes, so its rate and channel count describe the conversion rather
      # than the file. The header is what the file itself says.
      sample_rate: clip[:sample_rate] || header[:sample_rate],
      channels: clip[:channels] || header[:channels],
      bits: clip[:bits],
      peak: clip[:peak] || decoded[:peak],
      internal: Map.get(clip, :internal, false),
      internal_format: internal_format(),
      decoded: Map.get(decoded, :ran, false),
      decoder_available: decoder?,
      notes: notes(clip, header, decoded, decoder?)
    }
  end

  # Decode-on-demand — the gap Phase 0 flagged and this phase owns. Three of
  # probe's four facts need a *parsed* clip, and an mp3 voicemail cannot be
  # parsed without decoding, so the agent's only substitute for ears was blind
  # on exactly the input the acceptance walk starts from.
  #
  # Opt-in, and skipped whenever the direct parse already answered: a decode is
  # a subprocess plus the whole file materialized as PCM, and it could only
  # repeat what we just read. `peak` is the trigger rather than "unreadable",
  # because a 24-bit WAV parses fine and still has no peak.
  defp decoded_facts(clip, path, true) do
    if is_nil(clip[:peak]) do
      case SoundStudio.import_source(path) do
        {:ok, decoded} ->
          %{ran: true, peak: peak_of(decoded), duration_ms: SoundStudio.duration_ms(decoded)}

        {:error, reason} ->
          %{ran: false, decode_error: reason}
      end
    else
      %{ran: false}
    end
  end

  defp decoded_facts(_clip, _path, _decode?), do: %{ran: false}

  # What the file itself says, once parsed as a WAV. Peak needs samples, so it
  # is the fact only this path can supply.
  defp clip_facts(path) do
    case SoundStudio.read(path) do
      {:ok, clip} ->
        %{
          readable: true,
          internal: SoundStudio.internal?(clip),
          sample_rate: clip.sample_rate,
          channels: clip.channels,
          bits: clip.bits,
          duration_ms: SoundStudio.duration_ms(clip),
          peak: peak_of(clip)
        }

      {:error, reason} ->
        %{readable: false, internal: false, read_error: reason}
    end
  end

  # `afinfo`, which reads a header rather than decoding audio — so a long mp3
  # still gets a duration without materializing it as PCM.
  defp header_facts(path) do
    case SoundStudio.probe(path) do
      {:ok, facts} -> facts
      {:error, reason} -> %{probe_error: reason}
    end
  end

  # `peak/1` is defined for PCM16 only. A 24-bit WAV is a legitimate thing to
  # find on disk and must report "no peak", not raise.
  defp peak_of(%SoundStudio{bits: 16} = clip), do: SoundStudio.peak(clip)
  defp peak_of(%SoundStudio{}), do: nil

  defp notes(clip, header, decoded, decoder?) do
    [
      unreadable_note(clip[:read_error], decoded),
      prober_note(header[:probe_error]),
      format_note(clip),
      decoded_note(decoded),
      unless(decoder?,
        do:
          "No system decoder (/usr/bin/afconvert): only WAV already in the internal format can be imported."
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp unreadable_note(nil, _decoded), do: nil

  defp unreadable_note(reason, %{ran: true}),
    do:
      "Not readable as a WAV (#{inspect(reason)}): format comes from the header prober, and peak was measured by decoding."

  defp unreadable_note(reason, _decoded),
    do:
      "Not readable as a WAV (#{inspect(reason)}): format and duration come from the header prober, and peak needs a decode first — pass decode: true to measure it (it costs a full decode of the file)."

  defp decoded_note(%{ran: true}),
    do:
      "peak and duration_ms were measured by decoding the file to the Studio's internal format (PCM16 mono 22.05 kHz) — the clip an edit would actually operate on, not the original's own rate or channel count."

  defp decoded_note(%{decode_error: reason}),
    do:
      "decode: true was asked for and the decode failed (#{inspect(reason)}), so there is still no peak for this file."

  defp decoded_note(_decoded), do: nil

  defp prober_note(nil), do: nil

  defp prober_note(reason),
    do: "The header prober could not answer (#{inspect(reason)})."

  defp format_note(%{readable: true, internal: false}),
    do: "Not in the Studio's internal format — editing it means importing through the decoder."

  defp format_note(_clip), do: nil

  # ---------------------------------------------------------------------------
  # Transcripts — discovery, with no timings and no recognizer
  # ---------------------------------------------------------------------------

  def sound_transcript_search(%{"query" => query} = args) when is_binary(query) do
    with {:ok, opts} <- transcript_opts(args) do
      hits = Transcripts.search(query, opts)

      {:ok,
       %{
         query: query,
         kind: opts[:kind],
         with_recording: opts[:with_recording],
         whole_word: opts[:whole_word],
         count: length(hits),
         hits: hits,
         notes: transcript_notes(hits, opts)
       }}
    end
  end

  def sound_transcript_search(_args), do: {:error, :missing_query}

  def sound_transcript_words(args \\ %{}) do
    with {:ok, opts} <- transcript_opts(args) do
      words =
        Enum.map(Transcripts.top_words(opts), fn {word, count} -> %{word: word, count: count} end)

      {:ok,
       %{
         kind: opts[:kind],
         with_recording: opts[:with_recording],
         min_count: opts[:min_count],
         count: length(words),
         words: words,
         notes: [
           "These counts are a FLOOR, not a census: Twilio's transcriber drops and mangles words on 8 kHz telephony audio, so real takes hide under misrecognitions. A recurring nonsense word is usually a real word the transcriber keeps missing — searching for the nonsense is often how you find the take.",
           "Transcripts carry no timings. These words are not cuttable until the source has an index (sound_index_list)."
         ]
       }}
    end
  end

  def sound_corpus(args \\ %{}) do
    with {:ok, opts} <- transcript_opts(args) do
      coverage = Transcripts.coverage(Keyword.take(opts, [:kind, :since]))
      {:ok, Map.put(coverage, :notes, corpus_notes(coverage))}
    end
  end

  # The dev-workspace trap, said as a number rather than as silence: transcript
  # search defaults to `with_recording: true`, and a workspace whose Library root
  # holds no recordings answers every query with `[]`. That reads as "broken"
  # unless something says the audio is simply elsewhere.
  defp corpus_notes(coverage) do
    [
      if(coverage.events == 0,
        do:
          "No events of this kind in this workspace at all. If you expected some, the recordings and their rows live under the configured workspace, not the dev one."
      ),
      if(coverage.with_recording_path > 0 and coverage.recordings_on_disk == 0,
        do:
          "No recording named by these events is on disk under the Library root, so sound_transcript_search (with_recording defaults to true) will return nothing here. This is the normal state of a dev workspace. Pass with_recording: false to search the text anyway — but nothing found that way can be cut."
      ),
      if(coverage.missing_audio > 0 and coverage.recordings_on_disk > 0,
        do:
          "#{coverage.missing_audio} event(s) name a recording that is not on disk (pruned, moved, or the fetch failed). Those transcripts are searchable with with_recording: false and are not cuttable."
      ),
      "duration_seconds is Twilio's reported call length, not measured from the files — treat it as approximate."
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp transcript_notes([], opts) do
    [
      "No transcript contains that. Report it that way, not as \"you have no takes\": the transcriber mangles telephony audio, so absence from the text is weak evidence of absence from the audio.",
      if(opts[:with_recording],
        do:
          "Only events whose audio is on disk were searched. Run sound_corpus — if recordings_on_disk is 0, that is why this is empty, and with_recording: false searches every transcript."
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp transcript_notes(_hits, _opts) do
    [
      "Each hit is a candidate, not a confirmation — the excerpt is there so you can triage without listening.",
      "A transcript carries no timings. To cut one of these, its source needs a word index (sound_index_list / sound_index_import)."
    ]
  end

  defp transcript_opts(args) do
    case since(Map.get(args, "since")) do
      {:error, _reason} = error ->
        error

      parsed ->
        {:ok,
         [
           kind: kind(Map.get(args, "kind")),
           with_recording: boolean(Map.get(args, "with_recording"), true),
           whole_word: boolean(Map.get(args, "whole_word"), true),
           min_count: positive_integer(Map.get(args, "min_count"), 1),
           limit: positive_integer(Map.get(args, "limit"), @default_transcript_limit),
           since: parsed
         ]}
    end
  end

  defp kind(nil), do: "voicemail"
  defp kind("any"), do: :any
  defp kind(kind) when is_binary(kind), do: kind
  defp kind(_kind), do: "voicemail"

  defp since(nil), do: nil

  defp since(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> {:error, :invalid_since}
    end
  end

  defp since(_value), do: {:error, :invalid_since}

  # ---------------------------------------------------------------------------
  # The word index — words with timings, which is what a cut needs
  # ---------------------------------------------------------------------------

  def sound_index_list(_args \\ %{}) do
    indexes = Enum.map(Index.list(), &index_summary/1)

    {:ok,
     %{
       dir: Index.dir(),
       count: length(indexes),
       indexes: indexes,
       notes: [
         "An index whose audio_present is false describes a source that is no longer in sounds/studio/ — its words cannot be cut until the audio is back under that exact basename."
       ]
     }}
  end

  defp index_summary(source) do
    base = %{source: source, audio_present: SoundStudio.path_for(source) != nil}

    case Index.load(source) do
      {:ok, index} ->
        Map.merge(base, %{
          words: length(index.words),
          origin: index.origin,
          language: index.language,
          indexed_at: index.indexed_at,
          error: nil
        })

      {:error, reason} ->
        Map.merge(base, %{words: nil, origin: nil, language: nil, indexed_at: nil, error: reason})
    end
  end

  def sound_index_words(args \\ %{}) do
    opts = index_opts(args)

    case blank_to_nil(Map.get(args, "word")) do
      nil -> {:ok, indexed_vocabulary(args, opts)}
      word -> {:ok, indexed_takes(word, opts)}
    end
  end

  defp indexed_vocabulary(args, opts) do
    counts = Index.words_available(opts)

    words =
      counts
      |> Enum.sort_by(fn {word, count} -> {-count, word} end)
      |> Enum.take(positive_integer(Map.get(args, "limit"), @default_word_limit))
      |> Enum.map(fn {word, takes} -> %{word: word, takes: takes} end)

    %{
      source: opts[:source],
      min_confidence: opts[:min_confidence],
      distinct_words: map_size(counts),
      indexed_sources: length(Index.list()),
      words: words,
      notes: vocabulary_notes(counts)
    }
  end

  defp indexed_takes(word, opts) do
    takes = Index.takes(word, opts)

    %{
      word: word,
      takes: takes,
      source: opts[:source],
      min_confidence: opts[:min_confidence],
      notes: [
        "One take is a quotation; several are a cut-up. Use sound_index_search to see them and pick the best-confidence one.",
        "A word with zero takes may still be in un-indexed audio — this counts what is indexed, not what was said."
      ]
    }
  end

  defp vocabulary_notes(counts) when map_size(counts) == 0,
    do: [
      "Nothing is indexed in scope. Indexes live in sounds/studio/index/ and arrive via sound_index_import — a transcript alone cannot produce one, because it carries no timings."
    ]

  defp vocabulary_notes(_counts),
    do: [
      "takes is how many spliceable occurrences exist. A word you have once is a word you cannot really cut up."
    ]

  def sound_index_search(%{"query" => query} = args) when is_binary(query) do
    hits = query |> Index.search(index_opts(args)) |> Enum.map(&index_hit/1)

    {:ok,
     %{
       query: query,
       count: length(hits),
       source: Map.get(args, "source"),
       hits: hits,
       notes: [
         "Best confidence first. Each hit is already a cut: pass its source, start_ms and end_ms straight to sound_assemble.",
         "confidence ranks candidates; it is not a probability. Prefer the higher of two takes rather than thresholding on a number.",
         "A multi-word query matches consecutive words in one source's list, which is not the same as consecutive in time — a phrase hit can span a pause."
       ]
     }}
  end

  def sound_index_search(_args), do: {:error, :missing_query}

  # Flattened from `%{source:, word: %{...}}`, because every consumer of a hit
  # wants source + span together — that is the cut.
  defp index_hit(%{source: source, word: word}) do
    %{
      source: source,
      word: word.word,
      text: word.text,
      start_ms: word.start_ms,
      end_ms: word.end_ms,
      confidence: word.confidence
    }
  end

  # Every index lookup on this surface is scoped to ONE VOICE BANK, defaulting
  # to the active one. Without this the cut-up verbs would search across banks
  # and `sound_sentence` would splice a phrase from two speakers — the single
  # outcome `Cutup.Bank` exists to prevent, and one nothing downstream repairs.
  #
  # Defaulting rather than requiring keeps every pre-bank caller working: all
  # existing indexes belong to the default bank, so an agent that has never
  # heard of banks sees exactly what it saw before.
  defp index_opts(args) do
    [
      source: blank_to_nil(Map.get(args, "source")),
      bank: sentence_bank(args),
      min_confidence: number(Map.get(args, "min_confidence")),
      limit: positive_integer(Map.get(args, "limit"), nil)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # An explicit `bank` argument wins; otherwise the active bank. A blank string
  # means "every bank" and has to be asked for deliberately, because a corpus-wide
  # search is the right answer to "does this word exist anywhere?" and the wrong
  # one to everything else here.
  defp sentence_bank(args) do
    case Map.get(args, "bank") do
      "" -> nil
      bank when is_binary(bank) -> bank
      _other -> BusterClaw.Notifications.Cutup.Bank.active()
    end
  end

  # --- writing an index ------------------------------------------------------

  def sound_index_import(%{"source" => source, "words" => words} = args)
      when is_binary(source) and is_list(words) do
    existed? = Index.indexed?(source)

    if existed? and not boolean(Map.get(args, "overwrite"), false) do
      {:error, :index_exists}
    else
      import_index(source, words, args, existed?)
    end
  end

  def sound_index_import(%{"source" => source}) when is_binary(source),
    do: {:error, :invalid_words}

  def sound_index_import(_args), do: {:error, :missing_source}

  defp import_index(source, words, args, existed?) do
    opts = [
      origin: origin(Map.get(args, "origin")),
      language: blank_to_nil(Map.get(args, "language"))
    ]

    with {:ok, index} <- Index.build(source, words, opts),
         :ok <- Index.save(index) do
      {:ok,
       %{
         source: index.source,
         words: length(index.words),
         # Entries that could not be used are dropped rather than fatal, so the
         # only way a caller learns it handed over junk is this number.
         dropped: length(words) - length(index.words),
         origin: index.origin,
         language: index.language,
         replaced: existed?,
         audio_present: SoundStudio.path_for(index.source) != nil,
         path: Path.join(Index.dir(), index.source <> ".index.json")
       }}
    end
  end

  defp origin(value) when value in @origins, do: value
  defp origin(_value), do: "imported"

  def sound_index_delete(%{"source" => source}) when is_binary(source) do
    case Index.delete(source) do
      :ok ->
        {:ok,
         %{
           source: source,
           deleted: true,
           note: "The audio is untouched — only the word index was removed."
         }}

      {:error, _reason} = error ->
        error
    end
  end

  def sound_index_delete(_args), do: {:error, :missing_source}

  # ---------------------------------------------------------------------------
  # Alignment — the step that fills the index between search and assembly
  # ---------------------------------------------------------------------------

  def sound_align(args) when is_map(args) do
    overwrite? = boolean(Map.get(args, "overwrite"), false)
    detect = vad_opts(args)
    fit = align_opts(args)

    with {:ok, target} <- align_target(args),
         {:ok, replaced?} <- index_slot(target.source, overwrite?),
         {:ok, path} <- studio_source(target.source),
         {:ok, clip} <- internal_clip(path),
         {:ok, index, spans} <- aligned_index(target, clip, args, detect, fit),
         :ok <- Index.save(index) do
      {:ok, align_result(target, index, spans, clip, replaced?, detect ++ fit)}
    end
  end

  def sound_align(_args), do: {:error, :missing_source}

  # Two ways in, and they differ only in where the transcript comes from.
  # `event_id` is the easy path — the app stored both the recording and Twilio's
  # text — and an explicit `transcript` still wins there, because the transcriber
  # mangles telephony audio and a corrected line is the cheapest improvement
  # available to this whole feature.
  defp align_target(%{"event_id" => id} = args) when not is_nil(id) and id != "" do
    with {:ok, event_id} <- event_id(id),
         {:ok, event} <- fetch_event(event_id),
         {:ok, relative} <- recording_of(event),
         {:ok, _path} <- under_library(relative),
         {:ok, source} <- align_source(args, relative),
         {:ok, transcript} <- align_transcript(args, event) do
      {:ok, %{source: source, transcript: transcript, event_id: event.id, library_path: relative}}
    end
  end

  defp align_target(%{"source" => source} = args) when is_binary(source) do
    with {:ok, name} <- validate_name(source),
         {:ok, transcript} <- align_transcript(args, nil) do
      {:ok, %{source: name, transcript: transcript, event_id: nil, library_path: nil}}
    end
  end

  defp align_target(_args), do: {:error, :missing_source}

  # With no `source` given, the index binds to the name `sound_import` would have
  # stored this recording under — same `stored_name/1`, so the two verbs cannot
  # disagree about what the imported clip is called. The `recording_path` is run
  # through `under_library/1` first, so nothing path-shaped is trusted here that
  # `sound_import` would have refused.
  defp align_source(args, relative) do
    case blank_to_nil(Map.get(args, "source")) do
      nil -> stored_name(Path.basename(relative))
      given -> validate_name(given)
    end
  end

  defp align_transcript(args, event) do
    case blank_to_nil(Map.get(args, "transcript")) || event_transcript(event) do
      nil -> {:error, transcript_error(event)}
      text -> {:ok, text}
    end
  end

  defp event_transcript(%Telephony.Event{transcript: text}), do: blank_to_nil(text)
  defp event_transcript(nil), do: nil

  # Distinguished because they call for different fixes: an event that carries no
  # text needs one supplied, a bare `source` was simply never given one.
  defp transcript_error(%Telephony.Event{}), do: :no_transcript
  defp transcript_error(nil), do: :missing_transcript

  # Checked *before* the audio is read, so a refusal to clobber costs nothing and
  # a hand-corrected index is never at risk of a slow accident.
  defp index_slot(source, overwrite?) do
    case {Index.indexed?(source), overwrite?} do
      {false, _overwrite?} -> {:ok, false}
      {true, true} -> {:ok, true}
      {true, false} -> {:error, :index_exists}
    end
  end

  # **This verb never imports.** An index is only useful if `Assemble` can
  # resolve its source by basename, and the honest answer to "that audio is not
  # here" is the name to run `sound_import` for — not a silent second write into
  # the studio that the caller did not ask for and cannot see in the result.
  defp studio_source(name) do
    case SoundStudio.path_for(name) do
      nil -> {:error, {:not_imported, name}}
      path -> {:ok, path}
    end
  end

  # The detector measures PCM16 mono and reports nothing at all on anything else,
  # so a non-internal clip would align to zero spans and look like silence rather
  # than like the format mismatch it is. Everything `sound_import` writes is
  # internal; this catches a file dropped into the studio by hand.
  defp internal_clip(path) do
    case SoundStudio.read(path) do
      {:ok, clip} ->
        if SoundStudio.internal?(clip), do: {:ok, clip}, else: {:error, :not_internal}

      {:error, _reason} = error ->
        error
    end
  end

  # VAD finds where sound happens; `Align` lays the transcript's words across
  # those spans. An alignment that produced no words is refused rather than
  # saved: an empty index helps nobody, and writing one would take the slot and
  # force `overwrite: true` on the retry that tuned the detector.
  defp aligned_index(target, clip, args, detect, fit) do
    spans = Vad.spans(clip, detect)

    # Hand `Align` the energy profile so it can pull each word boundary to a
    # nearby quiet instant instead of leaving it wherever the proportional
    # arithmetic landed — frequently mid-vowel, which is what made the first
    # assembled paragraph sound garbled. Same detector options as the spans, so
    # the two analyses agree about what counts as quiet.
    fit = Keyword.put_new_lazy(fit, :energy, fn -> Vad.energy_profile(clip, detect) end)

    case Align.align(target.transcript, spans, fit) do
      [] ->
        {:error, :no_alignment}

      words ->
        build = [origin: :aligned, language: blank_to_nil(Map.get(args, "language"))]

        with {:ok, index} <- Index.build(target.source, words, build) do
          {:ok, index, spans}
        end
    end
  end

  defp align_result(target, index, spans, clip, replaced?, opts) do
    speech = speech_ms(spans)
    placed = placed_ms(index.words)
    # Words tile the detected speech exactly, EXCEPT where one straddled a span
    # boundary and was trimmed to the span it mostly occupied. So this gap is
    # the audio no word covers — the only per-alignment quality figure here that
    # is exact rather than inferred, and the one thing the confidence spread
    # genuinely cannot tell you (see `confidence_summary/1`).
    unplaced = max(speech - placed, 0.0)

    %{
      source: index.source,
      path: Path.join(Index.dir(), index.source <> ".index.json"),
      event_id: target.event_id,
      library_path: target.library_path,
      words: length(index.words),
      # What the transcript asked for, against what the alignment could place.
      # A gap between the two is the cheapest sign the fit went badly.
      transcript_words: length(String.split(target.transcript, ~r/\s+/u, trim: true)),
      spans: length(spans),
      speech_ms: speech,
      placed_ms: placed,
      unplaced_ms: unplaced,
      duration_ms: SoundStudio.duration_ms(clip),
      origin: index.origin,
      language: index.language,
      confidence: confidence_summary(index.words),
      replaced: replaced?,
      audio_present: true,
      options: Map.new(opts),
      notes: align_notes(index, spans, unplaced, replaced?)
    }
  end

  defp speech_ms(spans), do: spans |> Enum.map(&(&1.end_ms - &1.start_ms)) |> Enum.sum()

  defp placed_ms(words), do: words |> Enum.map(&(&1.end_ms - &1.start_ms)) |> Enum.sum()

  # **A whole-recording plausibility figure, and it must not be read as a
  # per-word one.** `Align` scores a word against an *absolute* expectation of
  # ~200 ms per syllable — deliberately absolute, because deriving the rate from
  # this recording's own duration would be vacuous when the allotment is
  # proportional by construction. The consequence is that under the default
  # syllable weighting the ratio is identical for every word in one call, so
  # these three numbers are usually the same number three times and within-call
  # variation comes only from boundary clamping.
  #
  # What it does catch is the failure that matters: a transcript that does not
  # fit its audio at any rate people speak at. Twilio hallucinates a tail on
  # noisy voicemail, and 200 words over one second scores about 1e-7 each — the
  # whole batch falls out of a `min_confidence: 0.3` filter together.
  defp confidence_summary([]), do: nil

  defp confidence_summary(words) do
    sorted = words |> Enum.map(& &1.confidence) |> Enum.sort()

    %{min: List.first(sorted), median: median(sorted), max: List.last(sorted)}
  end

  defp median(sorted) do
    count = length(sorted)
    mid = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end

  defp align_notes(index, spans, unplaced_ms, replaced?) do
    [
      "These timings are APPROXIMATE and are meant to be replaced word by word as better ones arrive. Nothing recognized this audio: the detector found #{length(spans)} span(s) of activity and the transcript's words were shared out across them by syllable count, assuming a constant speech rate — which people do not have.",
      "confidence here is a plausibility figure for the RECORDING, not a per-word verdict: every word is scored against the same absolute expectation of ~200 ms per syllable, so under the default weighting the three numbers are usually one number three times. A flat spread is normal and means nothing; a LOW value means the transcript does not fit the audio at any rate people speak at, which is what a hallucinated or truncated transcript looks like.",
      "confidence tops out at 0.9 here, never 1.0 — 1.0 belongs to hand-marked timings, so min_confidence: 0.95 asks for those alone.",
      "A wrong word does not only mistime itself: the whole transcript shares one timeline, so a dropped or invented word slides EVERY word after it. Correct the text and re-run with overwrite before trusting anything downstream of the mistake.",
      "origin is aligned: the word SEQUENCE comes from the transcript but the TIMES are a proportional guess — no recogniser ran. A transcript error slides every word after it, and function words are systematically over-allotted. Correct by hand and re-import with sound_index_import and origin manual.",
      "The index is on disk now: sound_index_words says what is cuttable, sound_index_search returns hits that are already cuts, and sound_assemble splices them.",
      if(unplaced_ms > 1.0,
        do:
          "#{round(unplaced_ms)} ms of detected speech is covered by no word: that much audio was trimmed off words that straddled a span boundary and were clamped to the span they mostly occupied. Those words are fragments, and they are the only ones whose confidence was reduced individually."
      ),
      if(length(index.words) < length(spans),
        do:
          "Fewer words than spans: the audio contains activity the transcript does not account for — music, a second speaker, or text the transcriber dropped. Every word after a dropped one is mistimed, because the whole transcript shares one timeline."
      ),
      if(replaced?, do: "An existing index for this source was replaced.")
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Only overrides are passed on, so the defaults documented in the catalog stay
  # defined once — in `Vad` and `Align` — rather than being restated here where
  # they could drift.
  defp vad_opts(args) do
    [
      min_span_ms: number(Map.get(args, "min_span_ms")),
      min_silence_ms: number(Map.get(args, "min_silence_ms"))
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp align_opts(args) do
    [
      weight: weight(Map.get(args, "weight")),
      syllable_ms: number(Map.get(args, "syllable_ms")),
      # The two corrections that came out of the first real listen, both ON by
      # default. Exposed so they can be turned off and A/B'd by ear — a fix to
      # how something SOUNDS cannot be judged from a test, only from the pair.
      snap_to_energy: boolean(Map.get(args, "snap_to_energy")),
      snap_window_ms: number(Map.get(args, "snap_window_ms")),
      reduce_function_words: boolean(Map.get(args, "reduce_function_words")),
      function_word_scale: number(Map.get(args, "function_word_scale"))
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # Spelled out, like `weight/1` below: a wire caller supplies strings, and a
  # nil means "not given" rather than "false" so the module's own default wins.
  defp boolean(value) when value in [true, "true"], do: true
  defp boolean(value) when value in [false, "false"], do: false
  defp boolean(_value), do: nil

  # Spelled out rather than converted, because a wire caller must never be able
  # to name an atom this module did not choose.
  defp weight(value) when value in ["syllables", :syllables], do: :syllables
  defp weight(value) when value in ["characters", :characters], do: :characters
  defp weight(_value), do: nil

  # ---------------------------------------------------------------------------
  # Query by example — the matcher, reachable
  # ---------------------------------------------------------------------------

  # **The one verb where a real matcher produces the timings.** Everything above
  # is `Align`'s proportional arithmetic; this hands one confirmed instance of a
  # word to `Dtw` and finds the others by acoustic similarity, then writes them
  # back as `origin: :recognizer`.
  #
  # Cost is the design constraint and it is not close: a source with no cached
  # features costs ~109 s to analyse and ~155 ms once it is warm. So which
  # sources were cold is reported rather than absorbed, cold sources are warmed
  # one process each through `Features.warm/2` rather than sequentially, and
  # `warm_only: true` searches the already-cached set and names what it skipped.
  # Nothing here ever silently spends ten minutes.
  def sound_find(%{"source" => source} = args) when is_binary(source) do
    warm_only? = boolean(Map.get(args, "warm_only"), false)
    write? = boolean(Map.get(args, "write"), true)
    overwrite? = boolean(Map.get(args, "overwrite"), false)
    opts = find_opts(args)

    with {:ok, word, text} <- find_word(args),
         {:ok, name} <- validate_name(source),
         {:ok, from, to} <- find_span(args),
         {:ok, targets} <- find_targets(args),
         {:ok, template} <- find_template(name, from, to, warm_only?) do
      searched =
        targets
        |> search_targets(template, word, text, warm_only?, opts)
        |> record_writes(write?, overwrite?)

      {:ok, find_result(template, word, text, searched, opts, warm_only?, write?)}
    end
  end

  def sound_find(_args), do: {:error, :missing_source}

  defp find_word(args) do
    case blank_to_nil(Map.get(args, "word")) do
      nil ->
        {:error, :missing_word}

      text ->
        # The same normaliser the corpus side uses, or the two would drift and
        # a word written here would never be found by `sound_index_search`.
        case Index.normalize_word(text) do
          "" -> {:error, :invalid_word}
          word -> {:ok, word, text}
        end
    end
  end

  # Both bounds are required and neither is defaulted: a template is a *specific*
  # take somebody confirmed, and guessing either edge of it would silently change
  # what is being searched for.
  defp find_span(args) do
    from = number(Map.get(args, "start_ms"))
    to = number(Map.get(args, "end_ms"))

    cond do
      is_nil(from) or is_nil(to) -> {:error, :missing_span}
      from < 0 -> {:error, :invalid_span}
      to <= from -> {:error, :invalid_span}
      true -> {:ok, from * 1.0, to * 1.0}
    end
  end

  # Indexed sources by default, because those are the ones whose approximate
  # timings this verb exists to improve. A source with audio and no index is
  # reachable by naming it, and gets an index made of these matches alone.
  defp find_targets(args) do
    case Map.get(args, "targets") do
      nil -> at_least_one(Index.list())
      list when is_list(list) -> validated_targets(list)
      _other -> {:error, :invalid_targets}
    end
  end

  defp at_least_one([]), do: {:error, :no_targets}
  defp at_least_one(targets), do: {:ok, targets}

  defp validated_targets(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case entry do
        name when is_binary(name) ->
          case validate_name(name) do
            {:ok, clean} -> {:cont, {:ok, [clean | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end

        _other ->
          {:halt, {:error, :invalid_name}}
      end
    end)
    |> case do
      {:ok, names} -> names |> Enum.reverse() |> Enum.uniq() |> at_least_one()
      {:error, _reason} = error -> error
    end
  end

  # **The template is sliced out of the whole recording's normalised sequence**,
  # never computed from a cut-out clip: `Features` takes the cepstral mean over
  # the full file, and a mean taken over two words is substantially the speech
  # itself. Getting this backwards does not error, it just makes every distance
  # quietly wrong.
  defp find_template(source, from, to, warm_only?) do
    cached? = Features.cached?(source)

    if warm_only? and not cached? do
      {:error, {:template_not_cached, source}}
    else
      with {:ok, seq} <- Features.for_source(source) do
        slice_template(source, seq, from, to, cached?)
      end
    end
  end

  defp slice_template(source, seq, from, to, cached?) do
    frame0 = frame_at(from)
    frame1 = max(frame_at(to) - 1, frame0)

    case Enum.slice(seq, frame0, frame1 - frame0 + 1) do
      [] ->
        {:error, :empty_template}

      frames ->
        {:ok,
         %{
           source: source,
           start_ms: from,
           end_ms: to,
           frame0: frame0,
           frame1: frame0 + length(frames) - 1,
           frame_count: length(frames),
           cold: not cached?,
           frames: frames
         }}
    end
  end

  # The pinned 10 ms hop is the only thing converting a millisecond boundary into
  # the frame index `Features` and `Select` address, and `Types` is explicit that
  # the frame index IS the clock. Read from `Signal` rather than restated.
  defp frame_at(ms), do: max(trunc(ms / Signal.hop_ms()), 0)

  defp find_opts(args) do
    %{
      threshold: positive_number(Map.get(args, "threshold"), @default_find_threshold),
      limit: positive_integer(Map.get(args, "limit"), @default_find_limit)
    }
  end

  defp search_targets(targets, template, word, text, warm_only?, opts) do
    cold = Enum.reject(targets, &Features.cached?/1)

    # One file per process, which is what `Features.warm/2` is for. Searching a
    # cold corpus one source at a time would pay the ~109 s serially, and
    # `Signal`'s own measurement says the parallel split is most of the win.
    if not warm_only? and cold != [], do: Features.warm(cold)

    Enum.map(targets, fn target ->
      search_target(target, template, word, text, target in cold, warm_only?, opts)
    end)
  end

  defp search_target(target, template, word, text, cold?, warm_only?, opts) do
    base = %{source: target, cold: cold?, skipped: nil, error: nil, matches: []}

    if warm_only? and cold? do
      %{base | skipped: "not_cached"}
    else
      case Features.for_source(target) do
        {:ok, seq} -> %{base | matches: matches(template, seq, word, text, target, opts)}
        {:error, reason} -> %{base | error: reason}
      end
    end
  end

  # **No `:cmn` here, ever.** `Features` normalises the whole recording once and
  # caches that, so `Dtw`'s opt-in would subtract an already-zero mean over a
  # different window and silently rescale every distance — after which the
  # measured threshold means nothing, with no error to notice.
  defp matches(template, seq, word, text, target, opts) do
    template.frames
    |> Dtw.search(seq, threshold: opts.threshold, limit: opts.limit)
    |> Enum.map(fn match ->
      %{
        word: word,
        text: text,
        start_ms: match.start_ms,
        end_ms: match.end_ms,
        distance: match.distance,
        confidence: confidence_of(match.distance),
        template: template_span?(template, target, match)
      }
    end)
  end

  # A match on the template's own span in the template's own source is the input
  # coming back at a distance near zero. It is the cheapest proof the search
  # actually ran, and it is not a discovery — so it is reported and never written.
  defp template_span?(%{source: source} = template, source, match),
    do: match.start_ms < template.end_ms and template.start_ms < match.end_ms

  defp template_span?(_template, _target, _match), do: false

  # A DTW distance has no natural scale, so this is an anchored linear map onto
  # the 0.1–0.9 band and the anchors are the measured ones (STUDIO_ROADMAP Part
  # III): over 990 labelled pairs the same-speaker positives ran 2.97 to 9.23
  # with a median of 4.43, and nothing in the study exceeded 13.24.
  #
  # It tops out at 0.9 for the same reason `Align` does — 1.0 belongs to
  # hand-marked timings — and it **ranks rather than measures**, which is all
  # `t:Types.word/0` asks a confidence to do. `distance` is reported beside it so
  # nobody has to invert this to get the number that was actually computed.
  defp confidence_of(distance) do
    span = @worst_distance - @best_distance
    drop = (distance - @best_distance) / span * (@best_confidence - @worst_confidence)

    (@best_confidence - drop) |> max(@worst_confidence) |> min(@best_confidence)
  end

  defp record_writes(searched, false, _overwrite?),
    do: Enum.map(searched, &Map.merge(&1, no_write()))

  defp record_writes(searched, true, overwrite?) do
    Enum.map(searched, fn entry ->
      case {entry.error, Enum.reject(entry.matches, & &1.template)} do
        {nil, [_ | _] = writable} ->
          Map.merge(entry, write_index(entry.source, writable, overwrite?))

        _nothing ->
          Map.merge(entry, no_write())
      end
    end)
  end

  defp no_write do
    %{
      written: false,
      words: nil,
      added: 0,
      skipped_overlapping: 0,
      replaced: 0,
      previous_origin: nil,
      origin: nil
    }
  end

  # Matches are **merged** into whatever index the source already has, because an
  # aligned index is a set of proportional guesses and replacing three of its
  # words with measured ones is the entire point of this verb.
  #
  # An existing word whose span overlaps a match is kept and the match dropped,
  # unless `overwrite: true` — a hand-corrected timing is real work, and the
  # threshold study is explicit that about one in eight returned spans is wrong.
  #
  # **`origin` belongs to the whole index and there is no mixed value**, so a
  # merge relabels the file `:recognizer` while the aligned words underneath are
  # unchanged and still approximate. `previous_origin` is reported for exactly
  # that reason, and the note says it out loud.
  defp write_index(source, matches, overwrite?) do
    {existing, language, previous} = current_index(source)

    {kept, replaced, added} =
      if overwrite? do
        {stale, keep} = Enum.split_with(existing, &overlaps_any?(&1, matches))
        {keep, length(stale), matches}
      else
        {existing, 0, Enum.reject(matches, &overlaps_any?(&1, existing))}
      end

    entries =
      Enum.map(kept ++ added, &Map.take(&1, [:word, :text, :start_ms, :end_ms, :confidence]))

    with {:ok, index} <- Index.build(source, entries, origin: :recognizer, language: language),
         :ok <- Index.save(index) do
      %{
        written: true,
        words: length(index.words),
        added: length(added),
        skipped_overlapping: length(matches) - length(added),
        replaced: replaced,
        previous_origin: previous,
        origin: index.origin
      }
    else
      {:error, reason} -> Map.merge(no_write(), %{previous_origin: previous, error: reason})
    end
  end

  defp current_index(source) do
    case Index.load(source) do
      {:ok, index} -> {index.words, index.language, index.origin}
      {:error, _reason} -> {[], nil, nil}
    end
  end

  defp overlaps_any?(word, others),
    do: Enum.any?(others, &(word.start_ms < &1.end_ms and &1.start_ms < word.end_ms))

  defp find_result(template, word, text, sources, opts, warm_only?, write?) do
    matched = Enum.flat_map(sources, & &1.matches)
    discovered = Enum.reject(matched, & &1.template)
    skipped = Enum.filter(sources, &(&1.skipped != nil))

    %{
      word: word,
      text: text,
      template: Map.drop(template, [:frames]),
      threshold: opts.threshold,
      limit: opts.limit,
      warm_only: warm_only?,
      wrote: write?,
      counts: %{
        targets: length(sources),
        searched: Enum.count(sources, &(&1.skipped == nil and &1.error == nil)),
        skipped_cold: length(skipped),
        failed: Enum.count(sources, &(&1.error != nil)),
        matches: length(matched),
        new_matches: length(discovered),
        added: sources |> Enum.map(& &1.added) |> Enum.sum(),
        sources_with_matches: Enum.count(sources, &(&1.matches != []))
      },
      # Which sources this call had to analyse from scratch, which is the whole
      # of where its wall-clock time went.
      cold_sources: sources |> Enum.filter(& &1.cold) |> Enum.map(& &1.source),
      skipped_sources: Enum.map(skipped, & &1.source),
      distances: distance_summary(discovered),
      sources: sources,
      notes: find_notes(discovered, skipped, sources, opts, warm_only?, write?)
    }
  end

  defp distance_summary([]), do: nil

  defp distance_summary(matches) do
    sorted = matches |> Enum.map(& &1.distance) |> Enum.sort()

    %{min: List.first(sorted), median: median(sorted), max: List.last(sorted)}
  end

  defp find_notes(discovered, skipped, sources, opts, warm_only?, write?) do
    cold = Enum.filter(sources, & &1.cold)

    [
      "distance is what was measured; confidence is a RANKING derived from it, and 0.9 is this verb's ceiling because 1.0 means hand-marked. Nothing here transcribed anything: these spans sound like the template, which is not the same as being the same word.",
      "This is a SHORTLIST GENERATOR, not an oracle. Measured over 990 labelled pairs, threshold #{@default_find_threshold} finds about 93% of real takes and roughly one in eight returned spans is wrong. Listen before trusting one — sound_assemble a candidate on its own and play it.",
      "Matching is speaker- and channel-dependent BY DESIGN: the same word from a different caller scores about as far away as a different word from the same one. For assembling one person's voice that is the wanted behaviour, and it is why a corpus-wide sweep finds fewer takes than the transcripts suggest.",
      if(write?,
        do:
          "origin on an index is a property of the WHOLE file and there is no mixed value, so any index written here now reads recognizer while its older aligned words are unchanged and still proportional guesses. previous_origin per source is what says which ones those are."
      ),
      if(discovered == [],
        do:
          "Nothing matched above threshold #{opts.threshold}. Before lowering it, check that the template span is really the word — the measured band for real speech is 3 to 13, an order of magnitude above the 0.2–0.9 the synthetic tests suggested, and a threshold below about 3 will match nothing at all."
      ),
      if(skipped != [],
        do:
          "warm_only was set, so #{length(skipped)} source(s) with no cached features were SKIPPED, not searched: #{Enum.map_join(skipped, ", ", & &1.source)}. Those sources may well contain the word. Re-run without warm_only to analyse them, at roughly 109 s of CPU per five minutes of audio."
      ),
      if(not warm_only? and cold != [],
        do:
          "#{length(cold)} source(s) had no cached features and were analysed from scratch — that is where the wall-clock went. The cache is now warm, so asking again about this corpus costs milliseconds."
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  # ---------------------------------------------------------------------------
  # Import — the door into the studio
  # ---------------------------------------------------------------------------

  def sound_import(args) when is_map(args) do
    overwrite? = boolean(Map.get(args, "overwrite"), false)

    with {:ok, origin} <- import_origin(args),
         {:ok, target} <- stored_name(blank_to_nil(Map.get(args, "name")) || origin.name),
         {:ok, path, replaced?} <- studio_target(target, overwrite?),
         {:ok, clip, decoded?} <- import_clip(origin.path),
         :ok <- write_source(clip, path) do
      {:ok,
       %{
         name: target,
         path: path,
         event_id: origin.event_id,
         library_path: origin.relative,
         duration_ms: SoundStudio.duration_ms(clip),
         sample_rate: clip.sample_rate,
         channels: clip.channels,
         bits: clip.bits,
         peak: peak_of(clip),
         internal: SoundStudio.internal?(clip),
         internal_format: internal_format(),
         decoded: decoded?,
         decoder_available: SoundStudio.decoder_available?(),
         bytes: byte_size_of(path),
         replaced: replaced?,
         notes: import_notes(decoded?, replaced?)
       }}
    end
  end

  def sound_import(_args), do: {:error, :missing_source}

  # Where the file being imported comes from. `event_id` wins when both are
  # given: it is the acceptance path, and it names a recording the app stored
  # itself rather than a path a caller typed.
  defp import_origin(%{"event_id" => id}) when not is_nil(id) and id != "" do
    with {:ok, event_id} <- event_id(id),
         {:ok, event} <- fetch_event(event_id),
         {:ok, relative} <- recording_of(event),
         {:ok, path} <- under_library(relative) do
      {:ok, %{event_id: event.id, relative: relative, path: path, name: Path.basename(relative)}}
    end
  end

  defp import_origin(%{"path" => relative}) when is_binary(relative) do
    with {:ok, path} <- under_library(relative) do
      {:ok,
       %{event_id: nil, relative: String.trim(relative), path: path, name: Path.basename(path)}}
    end
  end

  # A path that is not a string at all is a bad path, not a missing one.
  defp import_origin(%{"path" => path}) when not is_nil(path), do: {:error, :invalid_path}

  defp import_origin(_args), do: {:error, :missing_source}

  # A wire caller may hand over "12" rather than 12, and `Repo.get/2` raises on
  # anything that is not castable — so the cast happens here, as a named error.
  defp event_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp event_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _other -> {:error, :invalid_event_id}
    end
  end

  defp event_id(_id), do: {:error, :invalid_event_id}

  defp fetch_event(id) do
    case Telephony.get_event(id) do
      nil -> {:error, :event_not_found}
      event -> {:ok, event}
    end
  end

  defp recording_of(%Telephony.Event{recording_path: path}) when is_binary(path) and path != "",
    do: {:ok, path}

  defp recording_of(%Telephony.Event{}), do: {:error, :no_recording}

  # **The security boundary of this module.** Everywhere else a caller supplies
  # a basename that is allowlisted against a directory listing; here a caller
  # supplies a path, so this function is the only thing standing between an
  # agent and every file this app can read.
  #
  # Two independent checks, because one of them being subtly wrong is the whole
  # risk: the segments are scanned before the filesystem is touched at all
  # (absolute, `~`, `..`, empty segment, null byte), and the *expanded* result
  # is then required to sit under the expanded root. The second check is what
  # catches anything the first one failed to imagine.
  #
  # Note that `recording_path` values go through it too. They were written by
  # the drain from a relay row, which makes them data from off this machine —
  # trusted enough to store, not trusted enough to join into a path unchecked.
  defp under_library(relative) when is_binary(relative) do
    with {:ok, root} <- library_root(),
         {:ok, clean} <- relative_path(relative),
         {:ok, path} <- contained(root, clean) do
      if File.regular?(path), do: {:ok, path}, else: {:error, :not_found}
    end
  end

  defp under_library(_relative), do: {:error, :invalid_path}

  # Read from the env rather than through `Artifact.root/0`, which raises when
  # unset — an unconfigured Library root is a named error here, not a crash.
  defp library_root do
    case Application.get_env(:buster_claw, :library_root) do
      root when is_binary(root) and root != "" -> {:ok, Path.expand(root)}
      _unset -> {:error, :no_library_root}
    end
  end

  defp relative_path(relative) do
    trimmed = String.trim(relative)
    segments = String.split(trimmed, "/")

    cond do
      trimmed == "" -> {:error, :invalid_path}
      String.contains?(trimmed, <<0>>) -> {:error, :invalid_path}
      Path.type(trimmed) != :relative -> {:error, :absolute_path}
      String.starts_with?(trimmed, "~") -> {:error, :absolute_path}
      Enum.any?(segments, &(&1 in ["..", "."])) -> {:error, :traversal}
      Enum.any?(segments, &(&1 == "")) -> {:error, :invalid_path}
      true -> {:ok, trimmed}
    end
  end

  defp contained(root, relative) do
    path = Path.expand(Path.join(root, relative))

    if String.starts_with?(path, root <> "/"), do: {:ok, path}, else: {:error, :traversal}
  end

  # `import_source/1` is the one door to the outside world and decides for
  # itself whether the decoder is needed. Asking it the same question first is
  # the only way to *report* which path it took — and whether the decoder ran is
  # exactly what a caller needs to know when the answer on another machine
  # would have been a refusal.
  defp import_clip(path) do
    decoded? = not already_internal?(path)

    case SoundStudio.import_source(path) do
      {:ok, clip} -> {:ok, clip, decoded?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp already_internal?(path) do
    case SoundStudio.read(path) do
      {:ok, clip} -> SoundStudio.internal?(clip)
      {:error, _reason} -> false
    end
  end

  defp import_notes(decoded?, replaced?) do
    [
      "Stored in sounds/studio/ as a SOURCE — raw material. It is not in the sound library and nothing is routed to it; probe it, cut it, and route it as separate deliberate acts.",
      if(decoded?,
        do:
          "The system decoder ran, so the stored clip was resampled and downmixed to PCM16 mono 22.05 kHz. Its peak is the peak of that conversion, which is the clip an edit will operate on."
      ),
      if(replaced?, do: "An existing source of this name was overwritten.")
    ]
    |> Enum.reject(&is_nil/1)
  end

  # ---------------------------------------------------------------------------
  # Assembly — the other verb that writes audio
  # ---------------------------------------------------------------------------

  def sound_assemble(%{"cuts" => cuts, "name" => name} = args)
      when is_list(cuts) and is_binary(name) do
    overwrite? = boolean(Map.get(args, "overwrite"), false)
    opts = assemble_opts(args)

    with {:ok, target} <- stored_name(name),
         {:ok, path, replaced?} <- studio_target(target, overwrite?),
         {:ok, clip} <- Assemble.build(Enum.map(cuts, &cut/1), opts),
         :ok <- write_source(clip, path) do
      {:ok,
       %{
         name: target,
         path: path,
         cuts: length(cuts),
         duration_ms: SoundStudio.duration_ms(clip),
         peak: peak_of(clip),
         bytes: byte_size_of(path),
         replaced: replaced?,
         options: Map.new(opts),
         notes: [
           "Written into sounds/studio/ as a new SOURCE. It is not in the sound library and nothing is routed to it — probe it with sound_probe, and routing stays a separate, deliberate act."
         ]
       }}
    end
  end

  def sound_assemble(%{"cuts" => cuts}) when is_list(cuts), do: {:error, :missing_name}
  def sound_assemble(_args), do: {:error, :empty_selection}

  # Forced to `.wav` because that is what both writers render: a sentence — or
  # an imported mp3 — saved under its original extension would be a WAV lying
  # about its container. Shared by `sound_assemble` and `sound_import` so the
  # two cannot disagree about what a legal stored name is.
  defp stored_name(name) do
    with {:ok, clean} <- validate_name(name) do
      {:ok, AudioName.safe_name(Path.rootname(clean) <> ".wav")}
    end
  end

  # A forty-word sentence that clobbers the voicemail it was cut from is
  # unrecoverable, so an existing name is refused unless the caller says
  # overwrite. `File.exists?/1` rather than the audio listing, so a non-audio
  # file squatting the name is still protected.
  defp studio_target(target, overwrite?) do
    path = Path.join(SoundStudio.dir(), target)
    exists? = File.exists?(path)

    cond do
      not exists? -> {:ok, path, false}
      overwrite? -> {:ok, path, true}
      true -> {:error, :name_taken}
    end
  end

  defp write_source(clip, path) do
    File.mkdir_p(SoundStudio.dir())
    SoundStudio.write(clip, path)
  end

  # Wire cuts arrive with string keys. Anything malformed is passed through
  # untouched so `Assemble` names the offending cut itself rather than being
  # handed a map this function invented.
  defp cut(entry) when is_map(entry) do
    source = pick(entry, "source", :source)
    from = number(pick(entry, "start_ms", :start_ms))
    to = number(pick(entry, "end_ms", :end_ms))

    if is_binary(source) and is_number(from) and is_number(to) do
      %{source: source, start_ms: from, end_ms: to}
    else
      entry
    end
  end

  defp cut(entry), do: entry

  # Only overrides are passed on, so `Assemble`'s documented defaults (pad 30 ms,
  # fade 8 ms, gap 60 ms, normalize on) stay defined in exactly one place.
  defp assemble_opts(args) do
    [
      pad_ms: number(Map.get(args, "pad_ms")),
      fade_ms: number(Map.get(args, "fade_ms")),
      gap_ms: number(Map.get(args, "gap_ms")),
      normalize: exact_boolean(Map.get(args, "normalize"))
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # Atom keys as well as string ones, so an internal caller and a wire caller
  # hand the assembler the same thing.
  defp pick(entry, string_key, atom_key),
    do: Map.get(entry, string_key, Map.get(entry, atom_key))

  # ---------------------------------------------------------------------------
  # A sentence, in one call — the whole feature end to end
  # ---------------------------------------------------------------------------

  # phrase -> tokens -> `Index.search/2` per word -> a lattice -> `Select.best/2`
  # -> `Assemble.build/2` -> a new source. `sound_assemble` is the manual version
  # of the last two steps and stays that way; this is the one that CHOOSES.
  #
  # Two things it refuses to be quiet about. **A word it could not find** is
  # named and, by default, fatal — a sentence silently missing three words is
  # worse than no sentence, and `allow_missing: true` is how someone says they
  # want the partial anyway. And **whether the lattice actually decided
  # anything**: `slots` against `candidates` is the honesty pair, because with
  # one take per word the search has nothing to do and its cost of 0.0 means
  # "best of one", not "good".
  def sound_sentence(%{"phrase" => phrase, "name" => name} = args)
      when is_binary(phrase) and is_binary(name) do
    overwrite? = boolean(Map.get(args, "overwrite"), false)
    allow_missing? = boolean(Map.get(args, "allow_missing"), false)
    warm? = boolean(Map.get(args, "warm"), false)
    opts = assemble_opts(args)

    with {:ok, target} <- stored_name(name),
         {:ok, path, replaced?} <- studio_target(target, overwrite?),
         {:ok, weights} <- sentence_weights(args),
         # The splice itself lives in `Cutup.Sentence`, so this command and the
         # Voice Library surface build sentences through ONE implementation —
         # two builders would have drifted on padding, fades and take choice,
         # which are precisely the things that decide whether it sounds right.
         {:ok, built} <-
           Sentence.build(phrase,
             bank: sentence_bank(args),
             allow_missing: allow_missing?,
             warm: warm?,
             index: sentence_index_opts(args),
             weights: weights,
             assemble: opts
           ),
         :ok <- write_source(built.clip, path) do
      # Three groups rather than ten positional arguments: what was written,
      # what was asked for, and what the search made of it.
      written = %{name: target, path: path, clip: built.clip, replaced: replaced?, options: opts}
      asked = %{phrase: phrase, slots: built.slots, missing: built.missing}

      {:ok, sentence_result(written, asked, built.plan, built.features)}
    end
  end

  def sound_sentence(%{"phrase" => phrase}) when is_binary(phrase), do: {:error, :missing_name}
  def sound_sentence(_args), do: {:error, :missing_phrase}

  defp sentence_index_opts(args), do: Keyword.put_new(index_opts(args), :limit, @default_takes)

  # Missing words are FATAL by default and the error names them. The alternative
  # — building the sentence out of whatever happened to exist — is the one
  # failure mode of this feature that nobody notices until they listen.
  # **This never blocks on a cold corpus unless asked.** A source with no cached
  # features costs ~109 s to analyse, so by default only the already-cached ones
  # are handed over; `Select` imputes the acoustic terms for the rest from the
  # population median and `imputed` reports how often that happened. `warm: true`
  # is the opt-in that pays the bill, one process per source.
  #
  # The features handed over are the whole recording's, already CMN'd by
  # `Features` — which is why nothing on this path enables `Dtw`'s own `:cmn`.
  # Spelled out rather than converted, like `weight/1` above: a wire caller must
  # never be able to name an atom this module did not choose. `Select` refuses a
  # negative weight itself; this refuses a key it does not recognise, so a typo'd
  # weight cannot be silently ignored.
  defp sentence_weights(args) do
    case Map.get(args, "weights") do
      nil -> {:ok, []}
      map when is_map(map) and map_size(map) == 0 -> {:ok, []}
      map when is_map(map) -> parsed_weights(map)
      _other -> {:error, :invalid_weights}
    end
  end

  defp parsed_weights(map) do
    map
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      case weight_key(key) do
        nil -> {:halt, {:error, :invalid_weights}}
        atom when is_number(value) and value >= 0 -> {:cont, {:ok, [{atom, value * 1.0} | acc]}}
        _atom -> {:halt, {:error, :invalid_weights}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, [weights: Map.new(list)]}
      {:error, _reason} = error -> error
    end
  end

  defp weight_key(key) when is_atom(key) and not is_nil(key), do: weight_key(Atom.to_string(key))
  defp weight_key("confidence"), do: :confidence
  defp weight_key("duration"), do: :duration
  defp weight_key("boundary"), do: :boundary
  defp weight_key("typicality"), do: :typicality
  defp weight_key("spectral"), do: :spectral
  defp weight_key("level"), do: :level
  defp weight_key(_other), do: nil

  # `written` is the file and how it was rendered, `asked` is the phrase and what
  # the index had for it, and the last two are the search's own answers. Grouped
  # rather than spread out positionally because this is the function a future
  # reader will come to modify, and ten arguments in a row is a shape nobody can
  # call correctly twice.
  defp sentence_result(written, asked, plan, features) do
    words =
      asked.slots
      |> Enum.zip(plan.path)
      |> Enum.map(fn {slot, pick} ->
        %{
          word: slot.word,
          text: slot.text,
          takes: length(slot.hits),
          source: pick.source,
          start_ms: pick.word.start_ms,
          end_ms: pick.word.end_ms,
          confidence: pick.word.confidence
        }
      end)

    %{
      name: written.name,
      path: written.path,
      phrase: asked.phrase,
      # First field after the file itself, and a list of words rather than a
      # count: this is the failure that must never be read past.
      # Already the words as TYPED — `Cutup.Sentence` maps them on the way out,
      # so a missing word is reported the way the caller wrote it rather than
      # normalized. Was `Enum.map(&1.text)` here until the splice moved.
      missing: asked.missing,
      words: words,
      sources: drawn_from(plan.cuts),
      duration_ms: SoundStudio.duration_ms(written.clip),
      peak: peak_of(written.clip),
      bytes: byte_size_of(written.path),
      replaced: written.replaced,
      selection: selection_report(plan),
      features: Map.drop(features, [:table]),
      options: Map.new(written.options),
      notes: sentence_notes(asked.missing, plan, features, written.replaced)
    }
  end

  defp drawn_from(cuts) do
    cuts
    |> Enum.frequencies_by(& &1.source)
    |> Enum.map(fn {source, words} -> %{source: source, words: words} end)
    |> Enum.sort_by(& &1.source)
  end

  # `slots` against `candidates` is the pair that keeps this honest — equal means
  # every word had exactly one take and the lattice decided nothing — and
  # `imputed` says how many cost terms were filled from the population median
  # because the acoustics were not available.
  defp selection_report(plan) do
    %{
      slots: plan.slots,
      candidates: plan.candidates,
      chose: plan.candidates > plan.slots,
      imputed: plan.imputed,
      target_total: plan.target_total,
      join_total: plan.join_total,
      total: plan.total,
      weights: plan.weights
    }
  end

  defp sentence_notes(missing, plan, features, replaced?) do
    [
      if(missing != [],
        do:
          "#{length(missing)} word(s) are NOT in this sentence because the index has no take of them: #{Enum.join(missing, ", ")}. Say so before playing it — the audio is a different sentence from the one that was asked for. sound_index_words says what IS available, and sound_find is how a word that exists in the audio gets into the index.",
        else: "Every word of the phrase was found and used."
      ),
      if(plan.candidates == plan.slots,
        do:
          "The lattice CHOSE NOTHING: #{plan.slots} slot(s), #{plan.candidates} candidate(s), so every word had exactly one take. The costs below are real arithmetic over a search with no alternatives, and a total of 0.0 means best-of-one rather than good. More recordings is the only fix for this one.",
        else:
          "#{plan.candidates} candidate takes across #{plan.slots} slot(s); the cheapest path was chosen. Costs are min-max normalised WITHIN this lattice, so 0.0 means best here and two sentences' totals cannot be compared."
      ),
      if(features.without_features != [],
        do:
          "No cached features for #{Enum.join(features.without_features, ", ")}, so the acoustic terms (typicality, and every seam touching those takes) were imputed from the median rather than measured — imputed says how often. Pass warm true to analyse them, at roughly 109 s of CPU per five minutes of audio and once only."
      ),
      if(plan.imputed.boundary > 0,
        do:
          "boundary is imputed for every candidate: this verb does not measure per-frame energy at the cut edges, so that term contributed nothing to the choice."
      ),
      "Written into sounds/studio/ as a new SOURCE. Nothing is installed as a chime and nothing is routed — sound_apply is that step, and it is deliberately separate.",
      if(replaced?, do: "An existing source of this name was overwritten.")
    ]
    |> Enum.reject(&is_nil/1)
  end

  # ---------------------------------------------------------------------------
  # Editing — one pure function each, rendered to a new source
  # ---------------------------------------------------------------------------

  def sound_trim(%{"source" => source} = args) when is_binary(source) do
    with {:ok, from, to} <- span(args) do
      edit(args, "trim", fn clip ->
        # `end_ms` resolves against the clip, which is the one part of the span
        # that cannot be checked before the audio is open.
        to = to || SoundStudio.duration_ms(clip)

        with {:ok, cut} <- SoundStudio.splice(clip, from, to) do
          {:ok, cut, %{start_ms: from, end_ms: to}}
        end
      end)
    end
  end

  def sound_trim(_args), do: {:error, :missing_source}

  # `end_ms` defaults to the end of the clip and `start_ms` to 0, so trimming a
  # tail is one argument. `splice/3` clamps out-of-range values to the clip and
  # refuses a span that ends at or before it starts, which is what a span
  # entirely past the end collapses to — reported as :empty_selection rather
  # than as a zero-length file.
  defp span(args) do
    from = Map.get(args, "start_ms")
    to = Map.get(args, "end_ms")

    cond do
      not (is_nil(from) or is_number(from)) -> {:error, :invalid_span}
      not (is_nil(to) or is_number(to)) -> {:error, :invalid_span}
      is_number(from) and from < 0 -> {:error, :invalid_span}
      true -> {:ok, from || 0, to}
    end
  end

  def sound_fade(%{"source" => source} = args) when is_binary(source) do
    with {:ok, in_ms, out_ms} <- ramps(args) do
      edit(args, "fade", fn clip ->
        {:ok, SoundStudio.fade(clip, in_ms: in_ms, out_ms: out_ms),
         %{in_ms: in_ms, out_ms: out_ms}}
      end)
    end
  end

  def sound_fade(_args), do: {:error, :missing_source}

  # A fade with neither ramp given is refused rather than silently written: it
  # would render a byte-identical copy under a new name, which reads as the verb
  # having done something when it did not.
  defp ramps(args) do
    in_ms = Map.get(args, "in_ms")
    out_ms = Map.get(args, "out_ms")

    cond do
      is_nil(in_ms) and is_nil(out_ms) -> {:error, :missing_fade}
      not (is_nil(in_ms) or is_number(in_ms)) -> {:error, :invalid_fade}
      not (is_nil(out_ms) or is_number(out_ms)) -> {:error, :invalid_fade}
      (in_ms || 0) < 0 or (out_ms || 0) < 0 -> {:error, :invalid_fade}
      true -> {:ok, in_ms || 0, out_ms || 0}
    end
  end

  def sound_normalize(%{"source" => source} = args) when is_binary(source) do
    with {:ok, target} <- normalize_target(args) do
      edit(args, "normalize", fn clip ->
        levelled =
          if target, do: SoundStudio.normalize(clip, target), else: SoundStudio.normalize(clip)

        # `target` is nil when the module's own default was used, so the number
        # that says what actually happened is `peak` beside `source_peak` — and
        # on digital silence they are both 0.0, because there is no gain that
        # makes zero louder.
        {:ok, levelled, %{target: target}}
      end)
    end
  end

  def sound_normalize(_args), do: {:error, :missing_source}

  # A target above 1.0 is not a louder sound, it is a clipped one — the samples
  # clamp at full scale — so it is refused rather than obeyed.
  defp normalize_target(args) do
    case Map.get(args, "target") do
      nil -> {:ok, nil}
      target when is_number(target) and target > 0 and target <= 1.0 -> {:ok, target}
      _other -> {:error, :invalid_target}
    end
  end

  def sound_concat(%{"sources" => sources, "name" => name} = args)
      when is_list(sources) and is_binary(name) do
    overwrite? = boolean(Map.get(args, "overwrite"), false)

    with {:ok, target} <- stored_name(name),
         {:ok, path, replaced?} <- studio_target(target, overwrite?),
         {:ok, loaded} <- concat_sources(sources),
         {:ok, joined} <- SoundStudio.concat(Enum.map(loaded, & &1.clip)),
         :ok <- write_source(joined, path) do
      {:ok,
       %{
         name: target,
         path: path,
         sources: Enum.map(loaded, &Map.take(&1, [:name, :duration_ms, :peak])),
         duration_ms: SoundStudio.duration_ms(joined),
         peak: peak_of(joined),
         bytes: byte_size_of(path),
         replaced: replaced?,
         notes:
           new_source_notes(replaced?) ++
             [
               "Joined end to end with no gap and no fade: every seam is a hard cut, which is the loudest click a join can make. sound_assemble is the verb that pads, micro-fades and levels each piece — use this one for whole clips that already end quietly."
             ]
       }}
    end
  end

  def sound_concat(%{"sources" => sources}) when is_list(sources), do: {:error, :missing_name}
  def sound_concat(_args), do: {:error, :empty_selection}

  # Order is the caller's, exactly as given — a concat is an arrangement, and
  # sorting or de-duplicating it would silently change what was asked for. A
  # source named twice is joined twice, on purpose.
  defp concat_sources([]), do: {:error, :empty_selection}

  defp concat_sources(sources) do
    Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, acc} ->
      case load_source(source) do
        {:ok, loaded} -> {:cont, {:ok, [loaded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
      {:error, _reason} = error -> error
    end
  end

  defp load_source(source) when is_binary(source) do
    with {:ok, name} <- validate_name(source),
         {:ok, path} <- studio_source(name),
         {:ok, clip} <- editable_clip(path) do
      {:ok,
       %{
         name: name,
         clip: clip,
         duration_ms: SoundStudio.duration_ms(clip),
         peak: peak_of(clip)
       }}
    end
  end

  defp load_source(_source), do: {:error, :invalid_name}

  # The shape every single-source edit has: resolve the source, refuse the
  # output name BEFORE doing the work, run one pure function, write the result.
  #
  # The name check sits ahead of the edit deliberately — the same reasoning as
  # `sound_align`'s index slot: a refusal to clobber should cost nothing, and
  # discovering it after a full render is how a caller learns to pass
  # `overwrite: true` reflexively.
  #
  # Which is why **each verb validates its own arguments before calling this**,
  # rather than inside `fun`. A bad `start_ms` reported as `:name_taken` because
  # the previous run of the same verb already took the derived name is a
  # genuinely misleading error, and it is what the ordering here would otherwise
  # produce.
  defp edit(args, verb, fun) do
    overwrite? = boolean(Map.get(args, "overwrite"), false)
    given = blank_to_nil(Map.get(args, "name"))

    with {:ok, source} <- validate_name(Map.get(args, "source")),
         {:ok, path} <- studio_source(source),
         {:ok, clip} <- editable_clip(path),
         {:ok, target} <- stored_name(given || derived_name(source, verb)),
         {:ok, out, replaced?} <- studio_target(target, overwrite?),
         {:ok, edited, extra} <- fun.(clip),
         :ok <- write_source(edited, out) do
      {:ok, edit_result(source, clip, target, out, edited, replaced?, extra)}
    end
  end

  # With no name given, the output is named after its input — `harbor.wav`
  # trimmed becomes `harbor-trim.wav`. Derived rather than required so a chain of
  # edits reads as one thought, and colliding with a previous run of the same
  # verb is a plain :name_taken rather than a silent overwrite.
  defp derived_name(source, verb), do: Path.rootname(source) <> "-" <> verb <> ".wav"

  # Editing is defined for PCM16 only: `fade/2` and `normalize/2` match on it,
  # and a 24-bit WAV dropped into the studio by hand would otherwise raise
  # instead of being refused. Everything `sound_import` writes qualifies.
  defp editable_clip(path) do
    case SoundStudio.read(path) do
      {:ok, %SoundStudio{bits: 16} = clip} -> {:ok, clip}
      {:ok, %SoundStudio{}} -> {:error, :unsupported_format}
      {:error, _reason} = error -> error
    end
  end

  # Both sides of the edit, because the agent cannot hear: the source's duration
  # and peak beside the result's are the whole of how it verifies that a trim
  # removed audio and a normalize moved a level.
  defp edit_result(source, clip, target, path, edited, replaced?, extra) do
    Map.merge(
      %{
        name: target,
        path: path,
        source: source,
        source_duration_ms: SoundStudio.duration_ms(clip),
        source_peak: peak_of(clip),
        duration_ms: SoundStudio.duration_ms(edited),
        peak: peak_of(edited),
        bytes: byte_size_of(path),
        replaced: replaced?,
        notes: new_source_notes(replaced?)
      },
      extra
    )
  end

  defp new_source_notes(replaced?) do
    [
      "Written into sounds/studio/ as a new SOURCE. It is not in the sound library and nothing is routed to it — sound_apply is the verb that installs a source as a chime and points a key at it.",
      if(replaced?, do: "An existing source of this name was overwritten.")
    ]
    |> Enum.reject(&is_nil/1)
  end

  # ---------------------------------------------------------------------------
  # Deleting a source
  # ---------------------------------------------------------------------------

  def sound_delete(%{"name" => name} = args) when is_binary(name) do
    with {:ok, clean} <- validate_name(name),
         {:ok, path} <- studio_source(clean),
         {:ok, index?} <- index_reference(clean, boolean(Map.get(args, "delete_index"), false)) do
      bytes = byte_size_of(path)

      case SoundStudio.delete(clean) do
        :ok ->
          {:ok,
           %{
             name: clean,
             path: path,
             bytes: bytes,
             deleted: true,
             index_deleted: index?,
             notes: delete_notes(index?)
           }}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def sound_delete(_args), do: {:error, :missing_name}

  # **A dangling index is the failure this refusal exists to prevent.** An index
  # is addressed by its source's basename, so deleting the audio leaves a word
  # list whose every hit resolves to nothing — `sound_index_search` keeps
  # returning cuts and `sound_assemble` refuses them one at a time as
  # :source_not_found, which is a confusing way to learn the audio is gone.
  #
  # So the default is to refuse and name the index, and taking it along is an
  # explicit second act: an aligned or hand-corrected index is real work, and
  # silently destroying it with the audio would be the worse half of the trade.
  defp index_reference(source, delete?) do
    case {Index.indexed?(source), delete?} do
      {false, _delete?} -> {:ok, false}
      {true, false} -> {:error, :source_indexed}
      {true, true} -> with :ok <- Index.delete(source), do: {:ok, true}
    end
  end

  defp delete_notes(true),
    do: [
      "The audio and its word index are both gone. Re-creating the index means re-importing the source and aligning it again."
    ]

  defp delete_notes(false),
    do: [
      "Only this studio source was removed. The sound library, the routing table and every other source are untouched."
    ]

  # ---------------------------------------------------------------------------
  # Apply — the gated verb, and the only one that changes what plays
  # ---------------------------------------------------------------------------

  def sound_apply(%{"source" => source, "route" => route} = args)
      when is_binary(source) and is_binary(route) do
    overwrite? = boolean(Map.get(args, "overwrite"), false)
    given = blank_to_nil(Map.get(args, "name"))

    with {:ok, clean} <- validate_name(source),
         {:ok, key} <- route_key(route),
         {:ok, path} <- studio_source(clean),
         {:ok, clip} <- editable_clip(path),
         {:ok, target} <- stored_name(given || clean),
         {:ok, shadowing?, replaced?} <- library_slot(target, overwrite?) do
      before = %{assigned: Map.get(Sound.sound_map(), key), plays: Sound.resolved(key)}

      with {:ok, installed} <- install_in_library(path, target, replaced?),
           :ok <- Sound.assign(key, installed) do
        {:ok, apply_result(clean, clip, installed, key, before, shadowing?, replaced?)}
      end
    end
  end

  def sound_apply(%{"source" => source}) when is_binary(source), do: {:error, :missing_route}
  def sound_apply(_args), do: {:error, :missing_source}

  # **Checked before a byte is written**, which is the whole point of validating
  # here rather than letting `Sound.assign/2` refuse afterwards: a typo'd key
  # that installed the file and then failed to route would leave a sound in the
  # library, nothing routed to it, and a person wondering why their chime never
  # fires. `sound_routes` lists every legal key.
  defp route_key(route) do
    key = String.trim(route)
    if key in Sound.route_keys(), do: {:ok, key}, else: {:error, :unknown_route}
  end

  # The library layer overrides the bundled set **by basename**, so a name is
  # taken in two different ways and only one of them is obvious. Installing over
  # an existing workspace sound replaces the operator's file; installing under a
  # bundled name (`alarm.wav`) silently replaces the built-in alarm for every key
  # that falls back to it — a much wider change than the one key being routed,
  # and invisible in the routing table. Both are refused unless asked for.
  defp library_slot(target, overwrite?) do
    workspace? = target in Sound.list()
    bundled? = target in Sound.bundled_list()

    cond do
      workspace? and not overwrite? -> {:error, :name_taken}
      bundled? and not overwrite? -> {:error, :shadows_bundled}
      true -> {:ok, bundled?, workspace?}
    end
  end

  # `install_file/2` is the documented door between working material and the
  # library, and it never overwrites — so the deliberate replacement, already
  # authorized above, is a copy. It hands back the name it actually used, and
  # that is the name routed, never the one asked for.
  defp install_in_library(path, target, false), do: Sound.install_file(path, target)

  defp install_in_library(path, target, true) do
    File.mkdir_p(Sound.dir())

    with :ok <- File.cp(path, Path.join(Sound.dir(), target)), do: {:ok, target}
  end

  defp apply_result(source, clip, installed, key, before, shadowing?, replaced?) do
    %{
      name: installed,
      path: Sound.path_for(installed),
      source: source,
      route: key,
      route_label: Sound.route_label(key),
      # The way back, in the result rather than in a note: what this key played
      # a moment ago, and whether that was an explicit assignment or an
      # inheritance. Nothing else records it.
      previous_sound: before.assigned,
      previously_played: before.plays,
      plays: Sound.resolved(key),
      duration_ms: SoundStudio.duration_ms(clip),
      peak: peak_of(clip),
      bytes: byte_size_of(Sound.path_for(installed) || ""),
      enabled: Sound.enabled?(),
      shadowing: shadowing?,
      replaced: replaced?,
      notes: apply_notes(installed, key, before, shadowing?, replaced?)
    }
  end

  defp apply_notes(installed, key, before, shadowing?, replaced?) do
    [
      "#{installed} now plays for #{Sound.route_label(key)} — unattended, whenever that notification fires. Say so plainly before doing this again.",
      if(before.plays && before.plays != installed,
        do:
          "It previously played #{before.plays}. To put that back, run sound_apply again with that sound, or sound_restore_defaults with routes true to clear every assignment."
      ),
      unless(Sound.enabled?(),
        do:
          "The master sound switch is OFF, so nothing plays at all right now — this routing takes effect when it is turned back on."
      ),
      if(shadowing?,
        do:
          "This name matches a bundled default, so the workspace copy now shadows it: EVERY key that falls back to that default plays this file, not only #{key}. sound_list reports it as shadowing."
      ),
      if(replaced?, do: "An existing library sound of this name was overwritten."),
      "The studio source is untouched — the library holds a copy, so editing the source again does not change what plays until you apply it again."
    ]
    |> Enum.reject(&is_nil/1)
  end

  # ---------------------------------------------------------------------------
  # The way back
  # ---------------------------------------------------------------------------

  def sound_restore_defaults(args \\ %{}) do
    copy? = boolean(Map.get(args, "sounds"), true)
    routes? = boolean(Map.get(args, "routes"), false)

    installed = if copy?, do: Sound.install_bundled(), else: %{copied: [], skipped: []}
    cleared = if routes?, do: clear_routes(), else: []

    {:ok,
     %{
       copied: installed.copied,
       skipped: installed.skipped,
       cleared_routes: cleared,
       counts: %{
         copied: length(installed.copied),
         skipped: length(installed.skipped),
         cleared: length(cleared)
       },
       still_missing: Sound.missing_from_workspace(),
       notes: restore_notes(copy?, routes?, installed)
     }}
  end

  # Clearing an entry is not routing a key to a default — it deletes the
  # assignment, so the key inherits again (source → kind → default → the bundled
  # chime named after it), which is the state a fresh install is in.
  defp clear_routes do
    keys = Sound.sound_map() |> Map.keys() |> Enum.sort()
    Enum.each(keys, &Sound.assign(&1, nil))
    keys
  end

  defp restore_notes(copy?, routes?, installed) do
    [
      if(copy?,
        do:
          "Bundled chimes are copied into sounds/, and a name already there is SKIPPED rather than overwritten — that file is your edit or your replacement. skipped is not a failure."
      ),
      if(copy? and installed.skipped != [] and installed.copied == [],
        do:
          "Nothing was copied: every bundled name already exists in the workspace. If one of those files is an agent's overwrite, delete it — the bundled default underneath comes back on its own."
      ),
      if(routes?,
        do:
          "Every routing assignment was cleared, so each key inherits again and falls back to its bundled chime. This does not delete any sound file."
      ),
      unless(routes?,
        do:
          "Routing was NOT touched: this restores files only. Pass routes true to also clear every assignment, which is the way back from a sound_apply."
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  # ---------------------------------------------------------------------------
  # Shared
  # ---------------------------------------------------------------------------

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp boolean(value, _default) when is_boolean(value), do: value
  defp boolean("true", _default), do: true
  defp boolean("false", _default), do: false
  defp boolean(_value, default), do: default

  defp exact_boolean(value) when is_boolean(value), do: value
  defp exact_boolean("true"), do: true
  defp exact_boolean("false"), do: false
  defp exact_boolean(_value), do: nil

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil

  defp positive_number(value, _default) when is_number(value) and value > 0, do: value * 1.0
  defp positive_number(_value, default), do: default

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp internal_format do
    {rate, channels, bits} = SoundStudio.internal_format()
    %{sample_rate: rate, channels: channels, bits: bits}
  end

  defp byte_size_of(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> nil
    end
  end
end
