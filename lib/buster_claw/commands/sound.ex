defmodule BusterClaw.Commands.Sound do
  @moduledoc """
  The `sound_*` command surface: the notification sound library, addressable.
  Delegated to from `BusterClaw.Commands`.

  Five verbs. `sound_list`, `sound_routes` and `sound_probe` are `:safe` reads
  over files they never open for writing; `sound_apply` routes a library sound
  to a notification key and is the one gated entry, because routing is the one
  act here that changes what the machine does unattended; `sound_restore_defaults`
  is the way back, `:restricted` but never gated, because gating an undo only
  strands the person using it.

  > **The Sound Studio lived beside these until 10-16** — `sound_sources`,
  > `sound_import`, the four editing verbs, `sound_delete`, and the four
  > microphone verbs, with the Mix editor at `/studio` behind them. Deleted whole
  > (`STUDIO_REMOVAL_ROADMAP`): the feature shipped and was never used. What is
  > left is the chime library and the one verb that routes it.

  **The library has two layers and the workspace wins.** `sounds/` overrides the
  bundled defaults *by basename* (`Sound.resolve_path/1`), so a listing that
  showed one flat set of names is how "I replaced the chime and nothing changed"
  becomes a bug report. `sound_list` therefore reports every name once, with the
  layer it resolves from and whether a bundled default is being shadowed.

  **The agent cannot hear.** `sound_probe` is its substitute for ears: what the
  file's header says — duration, sample rate, channels — read by `/usr/bin/afinfo`
  without decoding a byte. (Peak level needed the Studio's WAV parser and left
  with it.) A sound is named by basename, resolved against a real directory
  listing — workspace first, then the bundled default it would shadow — or by a
  path **relative to the Library root**, so a recording can be looked at where
  it landed. `under_library/1` is the whole of that reach: absolute paths, `~`,
  `..` and null bytes are refused before the filesystem is touched, and the
  expanded result is re-checked against the root.
  """
  alias BusterClaw.Notifications.Sound

  @workspace "workspace"
  @bundled "bundled"
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
  # One sound, described — the substitute for ears
  # ---------------------------------------------------------------------------

  def sound_probe(args) when is_map(args) do
    with {:ok, target} <- probe_target(args) do
      {:ok, describe(target)}
    end
  end

  def sound_probe(_args), do: {:error, :missing_name}

  # Two ways to name one file, in precedence order: a path under the Library
  # root, or a basename resolved against the two sound layers.
  defp probe_target(args) do
    cond do
      present?(args, "path") ->
        with {:ok, path} <- under_library(Map.get(args, "path")) do
          {:ok,
           %{
             name: Path.basename(path),
             layer: @library,
             path: path,
             library_path: String.trim(Map.get(args, "path"))
           }}
        end

      is_binary(Map.get(args, "name")) ->
        with {:ok, clean} <- validate_name(Map.get(args, "name")),
             {:ok, layer, path} <- locate(clean) do
          {:ok, %{name: clean, layer: layer, path: path, library_path: nil}}
        end

      true ->
        {:error, :missing_name}
    end
  end

  defp present?(args, key), do: not is_nil(Map.get(args, key)) and Map.get(args, key) != ""

  # Workspace library, then the bundled default it would shadow — the same
  # precedence the player uses.
  defp locate(name) do
    case {Sound.path_for(name), Sound.bundled_path_for(name)} do
      {path, _bundled} when is_binary(path) -> {:ok, @workspace, path}
      {_workspace, path} when is_binary(path) -> {:ok, @bundled, path}
      _none -> {:error, :not_found}
    end
  end

  # `afinfo` reads a header rather than decoding audio, so a long recording
  # still gets a duration without being materialized as PCM.
  defp describe(target) do
    header =
      case Sound.probe(target.path) do
        {:ok, facts} -> facts
        {:error, reason} -> %{probe_error: reason}
      end

    %{
      name: target.name,
      layer: target.layer,
      path: target.path,
      library_path: target.library_path,
      bytes: byte_size_of(target.path),
      duration_ms: header[:duration_ms],
      sample_rate: header[:sample_rate],
      channels: header[:channels],
      notes: Enum.reject([prober_note(header[:probe_error])], &is_nil/1)
    }
  end

  defp prober_note(nil), do: nil

  defp prober_note(reason),
    do:
      "The header prober could not answer (#{inspect(reason)}): format and duration are unknown."

  # ---------------------------------------------------------------------------
  # Apply — the gated verb, and the only one that changes what plays
  # ---------------------------------------------------------------------------

  def sound_apply(%{"source" => source, "route" => route})
      when is_binary(source) and is_binary(route) do
    with {:ok, clean} <- validate_name(source),
         {:ok, key} <- route_key(route),
         {:ok, layer, _path} <- locate(clean) do
      before = %{assigned: Map.get(Sound.sound_map(), key), plays: Sound.resolved(key)}

      with :ok <- Sound.assign(key, clean) do
        {:ok, apply_result(clean, layer, key, before)}
      end
    end
  end

  def sound_apply(%{"source" => source}) when is_binary(source), do: {:error, :missing_route}
  def sound_apply(_args), do: {:error, :missing_source}

  # **Checked before anything is written**, which is the whole point of
  # validating here rather than letting `Sound.assign/2` refuse afterwards: a
  # typo'd key must never be discovered later as a chime that does not fire.
  # `sound_routes` lists every legal key.
  defp route_key(route) do
    key = String.trim(route)
    if key in Sound.route_keys(), do: {:ok, key}, else: {:error, :unknown_route}
  end

  defp apply_result(name, layer, key, before) do
    %{
      name: name,
      layer: layer,
      path: Sound.resolve_path(name),
      route: key,
      route_label: Sound.route_label(key),
      # The way back, in the result rather than in a note: what this key played
      # a moment ago, and whether that was an explicit assignment or an
      # inheritance. Nothing else records it.
      previous_sound: before.assigned,
      previously_played: before.plays,
      plays: Sound.resolved(key),
      enabled: Sound.enabled?(),
      notes: apply_notes(name, key, before)
    }
  end

  defp apply_notes(name, key, before) do
    [
      "#{name} now plays for #{Sound.route_label(key)} — unattended, whenever that notification fires. Say so plainly before doing this again.",
      if(before.plays && before.plays != name,
        do:
          "It previously played #{before.plays}. To put that back, run sound_apply again with that sound, or sound_restore_defaults with routes true to clear every assignment."
      ),
      unless(Sound.enabled?(),
        do:
          "The master sound switch is OFF, so nothing plays at all right now — this routing takes effect when it is turned back on."
      )
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
  # Arguments and the one path-shaped input
  # ---------------------------------------------------------------------------

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

  defp boolean(value, _default) when is_boolean(value), do: value
  defp boolean("true", _default), do: true
  defp boolean("false", _default), do: false
  defp boolean(_value, default), do: default

  defp byte_size_of(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> nil
    end
  end
end
