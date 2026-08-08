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

  `sound_import` and `sound_assemble` are the only verbs here that write audio,
  and both write a new *source* — neither routes anything, which is why they are
  `:restricted` but not gated. Routing is the only act that changes what the
  machine does unattended.

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
  alias BusterClaw.Notifications.Cutup.Assemble
  alias BusterClaw.Notifications.Cutup.Index
  alias BusterClaw.Notifications.Cutup.Transcripts
  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Telephony

  @workspace "workspace"
  @bundled "bundled"
  @studio "studio"
  @library "library"

  @default_transcript_limit 50
  @default_word_limit 50
  @origins ~w(manual recognizer imported)

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

  defp index_opts(args) do
    [
      source: blank_to_nil(Map.get(args, "source")),
      min_confidence: number(Map.get(args, "min_confidence")),
      limit: positive_integer(Map.get(args, "limit"), nil)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
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
