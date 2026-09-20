defmodule BusterClaw.Commands.Sound do
  @moduledoc """
  The `sound_*` command surface — the Studio, addressable (STUDIO_ROADMAP Part I
  Phases 0/1 and Part III Phase A/B). Delegated to from `BusterClaw.Commands`.

  The Sound Studio is the one authoring surface in this app the agent cannot
  reach. The library verbs give it eyes and nothing else: `sound_list`,
  `sound_routes`, `sound_sources` and `sound_probe` are `:safe`, read files they
  never open for writing, and touch no setting.

  `sound_import` and the four editing verbs (`sound_trim`, `sound_fade`,
  `sound_normalize`, `sound_concat`) are the verbs here that write audio, and
  every one of them writes a new *source* — none routes anything, which is why
  they are `:restricted` but not gated. Routing is the only act that changes what
  the machine does unattended.

  > **The cut-up verbs lived here until 09-19** — transcripts, the word index,
  > `sound_align`, `sound_find`, `sound_sentence`, `sound_assemble` — about half
  > this file. They were deleted with the engine under them
  > (`CUTUP_DELETION_ROADMAP`), which is now its own project. What is left is the
  > sound library, the Studio's sources, and the edits Mix is built on.

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
  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Telephony

  @workspace "workspace"
  @bundled "bundled"
  @studio "studio"
  @library "library"

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
               "Joined end to end with no gap and no fade: every seam is a hard cut, which is the loudest click a join can make. Use this for whole clips that already end quietly, or sound_fade each piece first."
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
  # The name check sits ahead of the edit deliberately: a refusal to clobber
  # should cost nothing, and discovering it after a full render is how a caller
  # learns to pass `overwrite: true` reflexively.
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

  def sound_delete(%{"name" => name}) when is_binary(name) do
    with {:ok, clean} <- validate_name(name),
         {:ok, path} <- studio_source(clean) do
      bytes = byte_size_of(path)

      case SoundStudio.delete(clean) do
        :ok ->
          {:ok,
           %{
             name: clean,
             path: path,
             bytes: bytes,
             deleted: true,
             notes: [
               "Only this studio source was removed. The sound library, the routing table and every other source are untouched."
             ]
           }}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def sound_delete(_args), do: {:error, :missing_name}

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

  # The name to run `sound_import` for is the honest answer to "that audio is
  # not here" — never a silent second write into the studio.
  defp studio_source(name) do
    case SoundStudio.path_for(name) do
      nil -> {:error, {:not_imported, name}}
      path -> {:ok, path}
    end
  end

  # Forced to `.wav` because that is what every writer here renders: an imported
  # mp3 saved under its original extension would be a WAV lying about its
  # container. Shared by `sound_import` and the editing verbs so they cannot
  # disagree about what a legal stored name is.
  defp stored_name(name) do
    with {:ok, clean} <- validate_name(name) do
      {:ok, AudioName.safe_name(Path.rootname(clean) <> ".wav")}
    end
  end

  # An edit that clobbers the voicemail it was cut from is unrecoverable, so an
  # existing name is refused unless the caller says overwrite. `File.exists?/1`
  # rather than the audio listing, so a non-audio file squatting the name is
  # still protected.
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
