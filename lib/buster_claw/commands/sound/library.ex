defmodule BusterClaw.Commands.Sound.Library do
  @moduledoc """
  The sound **library** verbs — what the machine plays and why.

  `sound_list`, `sound_routes`, `sound_sources` and `sound_probe` are `:safe`
  reads over files they never open for writing. `sound_delete` removes studio
  working material only. `sound_apply` is the one gated verb in the whole
  `sound_*` surface: it copies a studio source into the library AND routes a
  key to it, which is the difference between "the agent made me a sound" and
  "the agent changed what my computer does at 3am"; `sound_restore_defaults`
  is the way back. Split out of `BusterClaw.Commands.Sound` on 10-16
  (CODE_QUALITY_SWEEP Phase 6) — that module is the facade and carries the
  surface's full story; the shared argument and source helpers are
  `Commands.Sound.Shared`.
  """
  alias BusterClaw.Commands.Sound.Shared
  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Studio.Editor

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
    dir = Editor.dir()

    sources =
      Enum.map(Editor.list(), fn name ->
        path = Path.join(dir, name)
        %{name: name, path: path, bytes: Shared.byte_size_of(path)}
      end)

    {:ok,
     %{
       dir: dir,
       count: length(sources),
       # Reported rather than assumed: without the system decoder, only WAV
       # already in the internal format can ever be imported here.
       decoder_available: Editor.decoder_available?(),
       internal_format: Shared.internal_format(),
       sources: sources
     }}
  end

  # ---------------------------------------------------------------------------
  # One sound, described — the substitute for ears
  # ---------------------------------------------------------------------------

  def sound_probe(args) when is_map(args) do
    with {:ok, target} <- probe_target(args) do
      {:ok, describe(target, Shared.boolean(Map.get(args, "decode"), false))}
    end
  end

  def sound_probe(_args), do: {:error, :missing_name}

  # Three ways to name one file, in precedence order. `event_id` and `path`
  # reach the Library root through the same funnel `sound_import` uses — the
  # point being that a file can be *looked at* before it is brought in, rather
  # than imported blind and probed afterwards.
  defp probe_target(args) do
    cond do
      present?(args, "path") ->
        with {:ok, origin} <- Shared.import_origin(args) do
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
        with {:ok, clean} <- Shared.validate_name(Map.get(args, "name")),
             {:ok, layer, path} <- locate(clean) do
          {:ok, %{name: clean, layer: layer, path: path, event_id: nil, library_path: nil}}
        end

      true ->
        {:error, :missing_name}
    end
  end

  defp present?(args, key), do: not is_nil(Map.get(args, key)) and Map.get(args, key) != ""

  # Workspace library, then the bundled default it would shadow, then the
  # studio's raw sources — the same precedence the player uses, extended to the
  # one store the player never reads.
  defp locate(name) do
    case {Sound.path_for(name), Sound.bundled_path_for(name), Editor.path_for(name)} do
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
    decoder? = Editor.decoder_available?()

    %{
      name: target.name,
      layer: target.layer,
      path: path,
      event_id: target.event_id,
      library_path: target.library_path,
      bytes: Shared.byte_size_of(path),
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
      internal_format: Shared.internal_format(),
      decoded: Map.get(decoded, :ran, false),
      decoder_available: decoder?,
      notes: notes(clip, header, decoded, decoder?)
    }
  end

  # Decode-on-demand — the gap Phase 0 flagged and this phase owns. Three of
  # probe's four facts need a *parsed* clip, and an mp3 recording cannot be
  # parsed without decoding, so the agent's only substitute for ears was blind
  # on exactly the input the acceptance walk starts from.
  #
  # Opt-in, and skipped whenever the direct parse already answered: a decode is
  # a subprocess plus the whole file materialized as PCM, and it could only
  # repeat what we just read. `peak` is the trigger rather than "unreadable",
  # because a 24-bit WAV parses fine and still has no peak.
  defp decoded_facts(clip, path, true) do
    if is_nil(clip[:peak]) do
      case Editor.import_source(path) do
        {:ok, decoded} ->
          %{
            ran: true,
            peak: Shared.peak_of(decoded),
            duration_ms: Editor.duration_ms(decoded)
          }

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
    case Editor.read(path) do
      {:ok, clip} ->
        %{
          readable: true,
          internal: Editor.internal?(clip),
          sample_rate: clip.sample_rate,
          channels: clip.channels,
          bits: clip.bits,
          duration_ms: Editor.duration_ms(clip),
          peak: Shared.peak_of(clip)
        }

      {:error, reason} ->
        %{readable: false, internal: false, read_error: reason}
    end
  end

  # `afinfo`, which reads a header rather than decoding audio — so a long mp3
  # still gets a duration without materializing it as PCM.
  defp header_facts(path) do
    case Editor.probe(path) do
      {:ok, facts} -> facts
      {:error, reason} -> %{probe_error: reason}
    end
  end

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
  # Deleting a source
  # ---------------------------------------------------------------------------

  def sound_delete(%{"name" => name}) when is_binary(name) do
    with {:ok, clean} <- Shared.validate_name(name),
         {:ok, path} <- Shared.studio_source(clean) do
      bytes = Shared.byte_size_of(path)

      case Editor.delete(clean) do
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
    overwrite? = Shared.boolean(Map.get(args, "overwrite"), false)
    given = Shared.blank_to_nil(Map.get(args, "name"))

    with {:ok, clean} <- Shared.validate_name(source),
         {:ok, key} <- route_key(route),
         {:ok, path} <- Shared.studio_source(clean),
         {:ok, clip} <- Shared.editable_clip(path),
         {:ok, target} <- Shared.stored_name(given || clean),
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
      duration_ms: Editor.duration_ms(clip),
      peak: Shared.peak_of(clip),
      bytes: Shared.byte_size_of(Sound.path_for(installed) || ""),
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
    copy? = Shared.boolean(Map.get(args, "sounds"), true)
    routes? = Shared.boolean(Map.get(args, "routes"), false)

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
end
