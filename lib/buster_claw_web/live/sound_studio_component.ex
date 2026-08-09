defmodule BusterClawWeb.SoundStudioComponent do
  @moduledoc """
  The homepage **Studio** sub-tab (SOUND_STUDIO_ROADMAP Phase 3) — every piece
  of mix in the workspace down the left, the selected one open on the right.

  This is the surface the editing core (`Notifications.SoundStudio`) was built
  under. The facts shown for a selection — duration, peak, format, which layer
  it resolved from — are read by that module, not guessed from the filename, so
  what the panel claims about a file is what an edit would actually operate on.

  ## Selection lives in the parent, on purpose

  Home sub-tabs render behind `:if`, which **removes** the DOM and discards the
  live_component along with it (MUSIC_ROADMAP Finding 2, inherited as
  SOUND_STUDIO_ROADMAP Part V landmine 2). A selection held here would be lost
  every time you glanced at Chat. So `StatusLive` owns `@studio_source` and
  passes it down; this component holds only *derived* state (the analysis of
  whatever is selected), which is cheap to recompute on remount.

  ## Preview is served from a route, never a blob

  The `<audio>` element points at `/notify/sound/:name`, `/phone/recording`, or
  `/music/track/:name`. CSP declares no `media-src`, so media falls back to
  `default-src 'self'` — which excludes `blob:`. A blob-based preview would work
  in dev (CSP is Report-Only there) and fail only in the packaged app.
  """
  use BusterClawWeb, :live_component

  # Imported, not aliased, so every call site in the template reads exactly as
  # it did before the extraction.
  import BusterClawWeb.SoundStudio.Catalog
  import BusterClawWeb.SoundStudio.Format

  alias BusterClawWeb.SoundStudio.Arranger
  alias BusterClawWeb.SoundStudio.Overlays
  alias BusterClawWeb.SoundStudio.Sidebar

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Music
  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Notifications.StudioMix
  alias BusterClaw.Settings
  alias BusterClaw.Telephony
  alias BusterClawWeb.MusicComponent

  # Analysing a source means reading it end to end, and for anything compressed
  # it means a decoder round trip. Fine for a chime; not something to do on
  # every render for a 60 MB FLAC. Past this, the panel shows what it knows for
  # free and says so rather than stalling the tab.
  @analysis_byte_cap 8_000_000

  # The sidebar entry that opens the full music library manager rather than a
  # single track.
  @music_library_id "music:__library__"

  # Matches the music library's cap. A long recording clears it; a video does not.
  @max_import_bytes 100_000_000
  @max_import_entries 10

  # `@name` inside ~H is an ASSIGN, so the limit is exposed as a function for
  # the sidebar's error copy — one number, still owned by the allow_upload.
  defp max_import_entries, do: @max_import_entries

  @impl true
  def mount(socket) do
    # The Studio's working folder (`sounds/studio/`) appears when the Studio does.
    BusterClaw.Notifications.SoundStudio.ensure()

    {:ok,
     socket
     |> assign(:groups, [])
     |> assign(:selected, nil)
     |> assign(:facts, nil)
     |> assign(:info, nil)
     |> assign(:assign_render, nil)
     |> assign(:note, nil)
     |> allow_upload(:import,
       # A MIME wildcard, NOT `SoundStudio.accepted_extensions/0`. LiveView's
       # `:accept` only takes extensions the `mime` package has a registered
       # type for, and `.m4a` has none — passing the real list raises on mount
       # and the whole tab fails to render (MUSIC_ROADMAP Phase 4, inherited as
       # SOUND_STUDIO_ROADMAP Part V landmine 3).
       #
       # Wider here is also the right shape: `SoundStudio.store/2` is the gate,
       # and it gates by DECODING. A file the picker allows and the server
       # refuses gets a reason; a file the picker blocks cannot even be tried.
       #
       # auto_upload: the Import button lives in the home tab bar (`toolbar/1`)
       # and opens the OS picker directly, so choosing files is the whole
       # gesture — each file lands as its upload completes, with no second
       # submit click hidden away in the sidebar.
       accept: ~w(audio/*),
       max_entries: @max_import_entries,
       max_file_size: @max_import_bytes,
       auto_upload: true,
       progress: &handle_import_progress/3
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    groups = groups()
    selected = find_source(groups, socket.assigns[:studio_source])

    {:ok,
     socket
     |> assign(:groups, groups)
     |> assign(:selected, selected)
     |> assign(:missing_bundled, length(Sound.missing_from_workspace()))
     |> assign(:facts, analyze(selected))
     |> load_mix(selected)}
  end

  # The open arrangement is read from disk rather than held in the socket, and
  # every mutation writes straight back. That makes Part V landmine 2 a
  # non-issue here for free: a tab switch discards this component, and the mix
  # is exactly where it was because it was never only in memory.
  defp load_mix(socket, %{kind: :mix, name: name}) do
    case StudioMix.load(name) do
      {:ok, mix} -> assign(socket, :mix, mix)
      {:error, _reason} -> assign(socket, :mix, nil)
    end
  end

  defp load_mix(socket, _selected), do: assign(socket, :mix, nil)

  # Resolve a source id to its entry in `groups/0` — which mix a render came from.
  defp resolve_source(id), do: find_source(groups(), id)

  # ---------------------------------------------------------------------------
  # The catalog
  # ---------------------------------------------------------------------------

  @doc "Every source the studio can open, grouped for the sidebar."
  def groups do
    [
      %{key: "mix", label: "Mixes", items: mix_items()},
      # Imports lead the material groups: this is the working mix, and the one
      # the operator fills themselves.
      %{key: "imports", label: "Imports", items: import_items()},
      %{key: "sounds", label: "Sounds", items: sound_items()},
      %{key: "recordings", label: "Recordings", items: recording_items()},
      %{key: "music", label: "Music", items: music_items()}
    ]
  end

  @doc """
  Every sidebar group key. Cheap on purpose — `groups/0` reads four directories
  and the telephony table, which is far too much work to answer "is this a real
  group?". A test asserts the two lists agree.
  """
  def group_keys, do: ~w(mix imports sounds recordings music)

  @collapsed_key "studio_collapsed_groups"

  @doc """
  Sidebar groups the operator has folded shut, by key.

  Persisted, because a fold that survives a tab switch and not a restart is a
  preference the app keeps forgetting. **Filtered against `group_keys/0` on
  read** — the same posture as `Sound.sound_map/0` dropping entries whose file
  is gone: a group the app stops shipping must not leave a key behind forever,
  and a hand-edited settings row cannot introduce one.
  """
  def collapsed_groups do
    case Jason.decode(Settings.get(@collapsed_key) || "[]") do
      {:ok, keys} when is_list(keys) -> Enum.filter(keys, &(&1 in group_keys()))
      _ -> []
    end
  end

  @doc "Store the folded set, dropping the row entirely when nothing is folded."
  def put_collapsed(keys) when is_list(keys) do
    case Enum.filter(keys, &(&1 in group_keys())) do
      [] -> Settings.delete(@collapsed_key)
      kept -> Settings.put(@collapsed_key, Jason.encode!(kept))
    end

    :ok
  end

  defp mix_items do
    Enum.map(StudioMix.list(), fn name ->
      %{
        id: "mix:" <> name,
        kind: :mix,
        name: name,
        label: name,
        sub: "arrangement",
        # A mix is not a file the browser can play; it has to be rendered
        # first, which is what the arranger's Render button is for.
        url: nil,
        path: nil
      }
    end)
  end

  defp import_items do
    Enum.map(SoundStudio.list(), fn name ->
      %{
        id: "import:" <> name,
        kind: :import,
        name: name,
        label: Path.rootname(name),
        sub: String.trim_leading(Path.extname(name), "."),
        url: ~p"/studio/file/#{name}",
        path: SoundStudio.path_for(name)
      }
    end)
  end

  @doc "The sidebar id that opens the music library manager."
  def music_library_id, do: @music_library_id

  # Everything in the `sounds/` folder, plus any built-in not yet copied there.
  #
  # The sidebar looked like a dump of system sounds once, and the cause was
  # `phx.digest`'s hashed duplicates (`alarm-<md5>.wav` beside `alarm.wav`),
  # since fixed in `Sound.bundled_list/0` — **not** the operator's own files.
  # Their sounds belong here: a scream and a bongo hit are exactly the raw
  # material this tab exists to cut up.
  #
  # Deduped by basename, because `Sound.resolve_path/1` only ever plays one of
  # the two layers — listing both would advertise a choice the resolver does not
  # offer. `yours` means the file is in the workspace (an override, or something
  # only you have); `built-in` means it still resolves to the shipped copy.
  defp sound_items do
    workspace = MapSet.new(Sound.list())

    (Sound.list() ++ Sound.bundled_list())
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn name ->
      %{
        id: "sound:" <> name,
        kind: :sound,
        name: name,
        label: Path.rootname(name),
        sub: if(MapSet.member?(workspace, name), do: "yours", else: "built-in"),
        url: ~p"/notify/sound/#{name}",
        path: Sound.resolve_path(name)
      }
    end)
  end

  defp recording_items do
    Telephony.list_events(kind: "voicemail", limit: 50)
    |> Enum.filter(& &1.recording_path)
    |> Enum.map(fn event ->
      %{
        id: "recording:#{event.id}",
        kind: :recording,
        name: Path.basename(event.recording_path),
        label: event.from_number || "Unknown caller",
        sub: occurred(event.occurred_at),
        url: ~p"/phone/recording?path=#{event.recording_path}",
        path: Path.join(Artifact.root(), event.recording_path)
      }
    end)
  end

  defp music_items do
    tracks =
      Enum.map(Music.tracks(), fn track ->
        %{
          id: "music:" <> track.name,
          kind: :music,
          name: track.name,
          label: track.title,
          sub: track.artist,
          url: ~p"/music/track/#{track.name}",
          path: Music.path_for(track.name)
        }
      end)

    # The manager rides at the top of its own group so uploading, queueing, and
    # deleting keep a home after the Music tab became the Studio.
    [
      %{
        id: @music_library_id,
        kind: :library,
        name: nil,
        label: "Library manager",
        sub: "upload · queue · delete",
        url: nil,
        path: nil
      }
      | tracks
    ]
  end

  defp occurred(nil), do: nil
  defp occurred(at), do: Calendar.strftime(at, "%b %-d, %-I:%M %p")

  # ---------------------------------------------------------------------------
  # Import
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Audio arrangements
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("new_mix", %{"name" => name}, socket) do
    case StudioMix.create(name) do
      {:ok, created} ->
        send(self(), {:studio_select, "mix:" <> created})
        {:noreply, socket |> assign(:groups, groups()) |> assign(:note, {:info, "New mix."})}

      {:error, :invalid_name} ->
        {:noreply, assign(socket, :note, {:error, "Give the mix a name."})}

      {:error, _reason} ->
        {:noreply, assign(socket, :note, {:error, "Couldn't create that mix."})}
    end
  end

  def handle_event("add_track", _params, socket) do
    {:noreply, save_mix(socket, StudioMix.add_track(socket.assigns.mix))}
  end

  def handle_event("remove_track", %{"id" => track_id}, socket) do
    {:noreply, save_mix(socket, StudioMix.remove_track(socket.assigns.mix, track_id))}
  end

  # Mute and solo ride the same save path as every other edit, so they land in
  # the undo history and survive a tab switch like anything else that changes
  # what a render will contain.
  def handle_event("toggle_mute", %{"id" => track_id}, socket) do
    {:noreply, save_mix(socket, StudioMix.toggle_mute(socket.assigns.mix, track_id))}
  end

  def handle_event("toggle_solo", %{"id" => track_id}, socket) do
    {:noreply, save_mix(socket, StudioMix.toggle_solo(socket.assigns.mix, track_id))}
  end

  def handle_event("add_clip", %{"source" => source, "track" => track_id}, socket) do
    mix = socket.assigns.mix

    case clip_duration(source) do
      {:ok, duration} ->
        # Land it after whatever is already on that track, so successive adds
        # queue up instead of stacking invisibly at zero.
        at = StudioMix.track_end_ms(mix, track_id)

        {:noreply, save_mix(socket, StudioMix.add_clip(mix, track_id, source, at, duration))}

      {:error, reason} ->
        {:noreply, assign(socket, :note, {:error, trim_error(reason)})}
    end
  end

  # Clicking a clip lands HERE, not in `StatusLive`, even though the selection
  # lives there. LiveView resolves a hook's `pushEvent` against the `phx-target`
  # on the hook's own element, and this arranger carries one so `move_clip`
  # reaches the component — which means every event from that hook is
  # component-bound, whether or not it wants to be. So take it and pass it up.
  #
  # This cost a real bug: `select_clip` was originally handled only in
  # `StatusLive`, so in a browser every click on a clip hit a
  # FunctionClauseError and nothing was ever selected — which made copy and
  # paste look broken while undo worked fine. The tests missed it because
  # `render_hook(view, ...)` addresses the LiveView directly and skips the
  # `phx-target` resolution a real click goes through.
  def handle_event("select_clip", %{"id" => id}, socket) do
    send(self(), {:studio_select_clip, id})
    {:noreply, socket}
  end

  def handle_event("remove_clip", %{"id" => clip_id}, socket) do
    {:noreply, save_mix(socket, StudioMix.remove_clip(socket.assigns.mix, clip_id))}
  end

  # Pushed by the TrackArrange hook on drop.
  def handle_event("move_clip", %{"clip_id" => id, "track_id" => track, "start_ms" => at}, socket)
      when is_binary(id) and is_binary(track) and is_number(at) do
    {:noreply, save_mix(socket, StudioMix.move_clip(socket.assigns.mix, id, track, at))}
  end

  def handle_event("move_clip", _params, socket), do: {:noreply, socket}

  def handle_event("delete_mix", _params, socket) do
    StudioMix.delete(socket.assigns.mix.name)
    send(self(), {:studio_select, nil})
    {:noreply, socket |> assign(:groups, groups()) |> assign(:note, {:info, "Audio deleted."})}
  end

  # Pushed by the StudioContextMenu hook after its two-step confirm. The hook
  # only offers the menu on items the markup flagged deletable, but the server
  # is the gate: an id the dispatch below doesn't cover fails closed.
  def handle_event("delete_source", %{"id" => id}, socket) when is_binary(id) do
    case delete_source(id) do
      :ok ->
        # Clearing a deleted selection goes through the parent — selection is
        # StatusLive's state, and its update pass re-derives everything else.
        if socket.assigns.selected && socket.assigns.selected.id == id,
          do: send(self(), {:studio_select, nil})

        {:noreply, socket |> assign(:groups, groups()) |> assign(:note, delete_note(id))}

      {:error, :not_found} ->
        {:noreply, assign(socket, :note, {:error, "Nothing of yours to delete there."})}

      {:error, _reason} ->
        {:noreply, assign(socket, :note, {:error, "Couldn't delete that file."})}
    end
  end

  def handle_event("delete_source", _params, socket), do: {:noreply, socket}

  # Info: where the file actually is, how big, and what is in it. The length and
  # format come from the header probe rather than a decode, so this answers just
  # as fast for a 40-minute recording as for a chime.
  def handle_event("source_info", %{"id" => id}, socket) when is_binary(id) do
    case find_source(socket.assigns.groups, id) do
      %{path: path} = item when is_binary(path) ->
        {:noreply, assign(socket, :info, describe(item))}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("source_info", _params, socket), do: {:noreply, socket}

  def handle_event("close_info", _params, socket), do: {:noreply, assign(socket, :info, nil)}

  # "Add to new mix": the whole gesture in one click — a new arrangement named
  # after the source, with the source already on its first track. Landing in an
  # empty arrangement you then have to fill is the version nobody uses.
  def handle_event("new_mix_from_source", %{"id" => id}, socket) when is_binary(id) do
    with %{label: label} <- find_source(socket.assigns.groups, id),
         {:ok, duration} <- clip_duration(id),
         {:ok, name} <- StudioMix.create(label),
         {:ok, mix} <- StudioMix.load(name) do
      track = hd(mix.tracks)
      mix = StudioMix.add_clip(mix, track.id, id, 0, duration)
      StudioMix.save(mix)

      # Selection lives in StatusLive; opening the new arrangement is the point.
      send(self(), {:studio_select, "mix:" <> name})

      {:noreply,
       socket
       |> assign(:groups, groups())
       |> assign(:note, {:info, "New mix “#{name}” from #{label}."})}
    else
      {:error, reason} -> {:noreply, assign(socket, :note, {:error, new_mix_error(reason)})}
      _other -> {:noreply, socket}
    end
  end

  def handle_event("new_mix_from_source", _params, socket), do: {:noreply, socket}

  # Rename. The file moves and everything pointing at it moves with it: mix
  # clips are retargeted, and a sound's event routing is repointed by
  # `Sound.rename/2`. Renaming something a mix uses must not be a way to break
  # that mix quietly.
  def handle_event("rename_source", %{"id" => id, "name" => name}, socket)
      when is_binary(id) and is_binary(name) do
    case rename_source(id, name) do
      {:ok, new_id, note} ->
        # Follow the thing you renamed — losing your selection to a rename
        # reads as the app having lost the file.
        if socket.assigns.selected && socket.assigns.selected.id == id,
          do: send(self(), {:studio_select, new_id})

        {:noreply, socket |> assign(:groups, groups()) |> assign(:note, {:info, note})}

      {:error, reason} ->
        {:noreply, assign(socket, :note, {:error, rename_error(reason)})}
    end
  end

  def handle_event("rename_source", _params, socket), do: {:noreply, socket}

  def handle_event("render_mix", _params, socket) do
    mix = socket.assigns.mix

    case render_mix(mix) do
      {:ok, name} ->
        send(self(), {:studio_select, "sound:" <> name})

        {:noreply,
         socket
         |> assign(:groups, groups())
         # A render is the moment a mix stops being an arrangement and becomes a
         # sound — which is exactly when "and what is it FOR?" is worth asking.
         # Asking later means never asking.
         |> assign(:assign_render, name)
         |> assign(:note, {:info, "Rendered #{name}."})}

      {:error, reason} ->
        {:noreply, assign(socket, :note, {:error, render_error(reason)})}
    end
  end

  def handle_event("close_assign", _params, socket),
    do: {:noreply, assign(socket, :assign_render, nil)}

  # Point a notification at the freshly rendered mix. The file is already in the
  # library — the render put it there — so this is only the routing.
  #
  # Routed by NAME rather than installed as `alarm.wav`: this layer shadows
  # bundled chimes by basename, so the second would silently replace the
  # built-in alarm for good, and un-assigning later would not bring it back.
  def handle_event("assign_render", %{"key" => key, "name" => name}, socket)
      when is_binary(key) and is_binary(name) do
    case assign_route(key, name) do
      :ok ->
        {:noreply,
         socket
         |> assign(:assign_render, nil)
         |> assign(:groups, groups())
         |> assign(:note, {:info, "#{Sound.route_label(key)} now plays #{name}."})}

      _error ->
        {:noreply, assign(socket, :note, {:error, "Couldn't assign that sound."})}
    end
  end

  def handle_event("assign_render", _params, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Trim
  # ---------------------------------------------------------------------------

  def handle_event("preview_selection", _params, socket) do
    case socket.assigns.studio_trim do
      nil ->
        {:noreply, socket}

      %{from_ms: from, to_ms: to} ->
        # The hook scrubs the already-loaded element and stops early. No blob,
        # no temp file, no round trip — and no new CSP surface.
        {:noreply, push_event(socket, "studio:preview", %{from_ms: from, to_ms: to})}
    end
  end

  def handle_event("apply_trim", _params, socket) do
    %{selected: selected, studio_trim: trim} = socket.assigns

    case apply_trim(selected, trim) do
      {:ok, name} ->
        # Tell the parent to open the result: the selection lives up there, and
        # landing on the new file is the only way to hear what you just made.
        send(self(), {:studio_select, "import:" <> name})

        {:noreply,
         socket
         |> assign(:groups, groups())
         |> assign(:note, {:info, "Saved #{name}."})}

      {:error, reason} ->
        {:noreply, assign(socket, :note, {:error, trim_error(reason)})}
    end
  end

  def handle_event("install_bundled", _params, socket) do
    %{copied: copied} = Sound.install_bundled()

    note =
      case copied do
        [] -> {:info, "Already in sounds/."}
        names -> {:info, "Copied #{length(names)} into sounds/."}
      end

    {:noreply,
     socket
     |> assign(:groups, groups())
     |> assign(:missing_bundled, length(Sound.missing_from_workspace()))
     |> assign(:note, note)}
  end

  def handle_event("validate_import", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_import", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :import, ref)}
  end

  # Each file is consumed the moment ITS upload completes — auto_upload has no
  # submit event to batch on. The folder is re-read immediately for the same
  # reason the old batch handler did it: `update/2` will not fire again on its
  # own, and a successful import that does not appear in the list reads as a
  # failure.
  defp handle_import_progress(:import, entry, socket) do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, SoundStudio.store(path, entry.client_name)}
        end)

      case result do
        {:ok, name} ->
          {:noreply,
           socket |> assign(:groups, groups()) |> assign(:note, {:info, "Imported #{name}."})}

        {:error, reason} ->
          {:noreply,
           assign(socket, :note, {:error, "#{entry.client_name}: #{import_error(reason)}"})}
      end
    else
      {:noreply, socket}
    end
  end

  defp save_mix(socket, %StudioMix{} = mix) do
    # Hand the PREVIOUS state up before overwriting it, so undo has somewhere to
    # go. Sending the old state rather than letting the parent re-read it avoids
    # a race where this write has already landed on disk.
    if socket.assigns[:mix], do: send(self(), {:studio_history, socket.assigns.mix})

    StudioMix.save(mix)
    socket |> assign(:mix, mix) |> assign(:groups, groups())
  end

  defp save_mix(socket, _mix), do: socket

  # A clip caches its source's length for layout. The render re-reads the real
  # file, so a stale cache changes how wide a block draws, never what you hear.
  #
  # The header probe answers first because it is O(header): adding a 40-minute
  # recording to an arrangement should not decode 100 MB to learn how wide to
  # draw a rectangle. Decoding stays the fallback for anything `afinfo` cannot
  # read, which is also the path every bundled chime takes in tests.
  defp clip_duration(source) do
    case resolve_source(source) do
      %{path: path} when is_binary(path) ->
        case SoundStudio.probe(path) do
          {:ok, %{duration_ms: ms}} -> {:ok, ms}
          {:error, _reason} -> decoded_duration(path)
        end

      # No source, or one with no file behind it (an arrangement).
      _other ->
        {:error, :enoent}
    end
  end

  defp decoded_duration(path) do
    case SoundStudio.import_source(path) do
      {:ok, clip} -> {:ok, SoundStudio.duration_ms(clip)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_mix(%StudioMix{} = mix) do
    # Audible clips only: the mix must be what the arranger SHOWS it will be,
    # and a muted track that still rendered would make M a lie with a UI.
    placements =
      mix
      |> StudioMix.audible_clips()
      |> Enum.map(fn {_track, clip} -> placement(clip) end)

    cond do
      StudioMix.clips(mix) == [] ->
        {:error, :empty_mix}

      # Clips exist but mute/solo silenced every one — a different mistake
      # than an empty arrangement, deserving a different sentence.
      placements == [] ->
        {:error, :all_silenced}

      # A clip whose source was deleted or renamed since it was placed. Refuse
      # the whole render rather than quietly dropping it: a mix missing one
      # layer still sounds finished, and you would never know what was lost.
      Enum.any?(placements, &match?({:error, _}, &1)) ->
        {:error, :missing_source}

      true ->
        with {:ok, mixed} <- SoundStudio.mixdown(Enum.map(placements, fn {:ok, p} -> p end)) do
          install_render(mixed, mix.name <> "-mix")
        end
    end
  end

  # A render lands in `sounds/` — the library — not in `sounds/studio/`.
  #
  # The two folders mean different things: studio/ is what you are working ON,
  # sounds/ is what the app will play. A render is the finished thing, so this
  # is where it belongs, and putting it here is what makes it appear in
  # Settings → Notify's list with no further step. Nothing is lost by not also
  # keeping a studio/ copy: library sounds are addable as clips, so a render can
  # still be a layer in the next mix.
  #
  # Via a temp file so `Sound.install_file/2` stays the single door into the
  # library — it owns the never-overwrite rule, which matters here because this
  # layer shadows bundled chimes by basename.
  defp install_render(clip, suggested) do
    tmp =
      Path.join(System.tmp_dir!(), "bc-render-#{:erlang.unique_integer([:positive])}.wav")

    try do
      with :ok <- File.write(tmp, SoundStudio.render(clip)) do
        Sound.install_file(tmp, Path.rootname(suggested) <> ".wav")
      end
    after
      File.rm(tmp)
    end
  end

  defp placement(clip) do
    with %{path: path} when is_binary(path) <- resolve_source(clip.source),
         {:ok, decoded} <- SoundStudio.import_source(path) do
      {:ok, {decoded, clip.start_ms}}
    else
      _ -> {:error, clip.source}
    end
  end

  defp render_error(:empty_mix), do: "Add a clip before rendering."

  defp render_error(:all_silenced),
    do: "Every clip is muted — unmute or solo something first."

  defp render_error(:missing_source), do: "A clip's source is missing — nothing was rendered."
  defp render_error(:too_long), do: "That arrangement is longer than five minutes."
  defp render_error(:format_mismatch), do: "Those clips don't share a format."
  defp render_error(_other), do: "Couldn't render that mix."

  defp apply_trim(nil, _trim), do: {:error, :no_selection}
  defp apply_trim(_selected, nil), do: {:error, :no_selection}
  defp apply_trim(%{path: nil}, _trim), do: {:error, :enoent}

  defp apply_trim(%{path: path, name: name}, %{from_ms: from, to_ms: to}) do
    with {:ok, clip} <- SoundStudio.import_source(path),
         {:ok, cut} <- SoundStudio.splice(clip, from, to) do
      # A cut from the middle of a file starts and ends mid-waveform, and a
      # mid-waveform edge is a step from silence to full amplitude — the loudest
      # click a sound can have. These two ramps are DE-CLICKING, not shaping;
      # the fade tool (next) is the one that shapes.
      cut
      |> SoundStudio.fade(in_ms: 2, out_ms: 6)
      |> SoundStudio.save(Path.rootname(name) <> "-trim")
    end
  end

  defp trim_error(:empty_selection), do: "That selection is empty."
  defp trim_error(:no_selection), do: "Select part of the waveform first."
  defp trim_error(:unsupported_source), do: "Couldn't decode this file to trim it."
  defp trim_error(:no_decoder), do: "The system decoder is unavailable."
  defp trim_error(_other), do: "Couldn't save the trim."

  # A rejected file that does not say WHY is a support question, and "we tried
  # to decode it and could not" is a real answer.
  defp import_error(:unsupported_format), do: "Audio files only (MP3, M4A, AAC, WAV, OGG, FLAC)."
  defp import_error(:not_audio), do: "That file couldn't be decoded, whatever it is named."
  defp import_error(:enoent), do: "The upload didn't arrive."
  defp import_error(_other), do: "Couldn't import that file."

  # ---------------------------------------------------------------------------
  # The sidebar's right-click menu
  # ---------------------------------------------------------------------------

  # `Sound.assign/2` answers `{:ok, _}` / `:ok` depending on the Settings write;
  # only the refusal matters here.
  defp assign_route(key, name) do
    case Sound.assign(key, name) do
      {:error, reason} -> {:error, reason}
      _ok -> :ok
    end
  end

  # What Info shows. Length and format come from the header probe, not a decode:
  # O(header) at any file size, so a 40-minute recording answers as fast as a
  # chime. Peak is deliberately absent — that one genuinely needs every sample.
  defp describe(%{path: path} = item) do
    base = %{
      label: item.label,
      kind: item.kind,
      path: path,
      size: file_size(path),
      duration_ms: nil,
      rate: nil,
      channels: nil,
      note: nil
    }

    case SoundStudio.probe(path) do
      {:ok, probed} ->
        %{
          base
          | duration_ms: probed.duration_ms,
            rate: probed.sample_rate,
            channels: probed.channels
        }

      {:error, :not_found} ->
        %{base | note: "This file is gone from disk."}

      {:error, _reason} ->
        %{base | note: "Couldn't read this file's mix header."}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      {:error, _reason} -> nil
    end
  end

  # Each rename returns the new catalog id and the sentence to show. A file
  # rename also retargets every mix clip that pointed at the old id — the clip
  # stores a reference, which is what lets a mix survive its sources being
  # edited and exactly what a rename could otherwise orphan.
  defp rename_source("import:" <> old, stem), do: retargeting("import:", old, stem, SoundStudio)
  defp rename_source("music:" <> old, stem), do: retargeting("music:", old, stem, Music)
  defp rename_source("sound:" <> old, stem), do: retargeting("sound:", old, stem, Sound)

  defp rename_source("mix:" <> old, requested) do
    case StudioMix.rename(old, requested) do
      {:ok, new} -> {:ok, "mix:" <> new, "Renamed to #{new}."}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rename_source(_id, _name), do: {:error, :not_found}

  defp retargeting(prefix, old, stem, module) do
    case module.rename(old, stem) do
      {:ok, new} ->
        moved = StudioMix.retarget(prefix <> old, prefix <> new)
        {:ok, prefix <> new, "Renamed to #{Path.rootname(new)}." <> mixes_note(moved)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mixes_note(0), do: ""
  defp mixes_note(1), do: " One mix follows it."
  defp mixes_note(n), do: " #{n} mixes follow it."

  defp rename_error(:name_taken), do: "Something is already called that."
  defp rename_error(:invalid_name), do: "That name has nothing in it."
  defp rename_error(:not_found), do: "Nothing of yours to rename there."
  defp rename_error(_other), do: "Couldn't rename that."

  defp new_mix_error(:invalid_name), do: "That source's name can't become a mix name."
  defp new_mix_error(:enoent), do: "That file is gone from disk."
  defp new_mix_error(reason), do: trim_error(reason)

  # ---------------------------------------------------------------------------
  # Deletion
  # ---------------------------------------------------------------------------

  # What the menu may touch: files that are YOURS. A built-in chime has no
  # workspace file (deleting the override of one is how you get the built-in
  # back), and a voicemail recording belongs to the Phone surface — deleting
  # its file here would orphan the telephony record that points at it.

  # `Sound.delete/1` only ever removes the workspace layer, so a "built-in"
  # id sent here anyway returns :not_found — the fail-closed the handler wants.
  defp delete_source("import:" <> name), do: SoundStudio.delete(name)
  defp delete_source("mix:" <> name), do: StudioMix.delete(name)
  defp delete_source("music:" <> name), do: Music.delete(name)
  defp delete_source("sound:" <> name), do: Sound.delete(name)
  defp delete_source(_id), do: {:error, :not_found}

  # Deleting a sound override isn't loss, it's reversion — say so. But only
  # when a bundled copy actually stands behind it; a sound only you had is
  # simply gone.
  defp delete_note("sound:" <> name) do
    if name in Sound.bundled_list() do
      {:info, "Removed your #{Path.rootname(name)} — the built-in is back."}
    else
      {:info, "Deleted #{Path.rootname(name)}."}
    end
  end

  defp delete_note(id),
    do: {:info, "Deleted #{id |> String.split(":", parts: 2) |> List.last() |> Path.rootname()}."}

  # ---------------------------------------------------------------------------
  # Analysis — the Phase 1 core, put to work
  # ---------------------------------------------------------------------------

  defp analyze(nil), do: nil
  defp analyze(%{kind: :library}), do: nil
  defp analyze(%{path: nil}), do: nil

  defp analyze(%{path: path}) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @analysis_byte_cap ->
        case SoundStudio.import_source(path) do
          {:ok, clip} ->
            %{
              size: size,
              duration_ms: SoundStudio.duration_ms(clip),
              peak: SoundStudio.peak(clip),
              rate: clip.sample_rate,
              channels: clip.channels,
              error: nil
            }

          {:error, reason} ->
            %{size: size, duration_ms: nil, peak: nil, rate: nil, channels: nil, error: reason}
        end

      {:ok, %{size: size}} ->
        # Above the decode cap the header is still cheap to read: afinfo gives
        # length and format in O(header), so a twenty-minute recording shows a
        # real Length (and the trim tool keeps working — WaveTrim maps drags
        # through duration_ms). Only peak stays unmeasured, because peak
        # genuinely needs the decoded samples.
        case SoundStudio.probe(path) do
          {:ok, probed} ->
            %{
              size: size,
              duration_ms: probed.duration_ms,
              peak: nil,
              rate: probed.sample_rate,
              channels: probed.channels,
              error: :too_large
            }

          {:error, _reason} ->
            %{
              size: size,
              duration_ms: nil,
              peak: nil,
              rate: nil,
              channels: nil,
              error: :too_large
            }
        end

      {:error, reason} ->
        %{size: nil, duration_ms: nil, peak: nil, rate: nil, channels: nil, error: reason}
    end
  end

  defp analysis_note(:too_large), do: "Too large to decode inline — peak unmeasured."
  defp analysis_note(:no_decoder), do: "The system decoder is unavailable."
  defp analysis_note(:unsupported_source), do: "Couldn't decode this file."
  defp analysis_note(:enoent), do: "That file is gone from disk."
  defp analysis_note(_other), do: "Couldn't read this file."

  # The catalog minus mixes themselves: a mix cannot contain a mix, and the
  # library manager is not mix at all.

  # The detail pane's waveform takes its color from the source's KIND, using
  # the same triad the tracks cycle — so one glance at a blue wave says
  # "import" before the header is read. Each pair is {face, shade}; the shade
  # is the face at ~40%, matching the original hazard pairing.
  #
  # Recordings keep the house color rather than growing a fourth hue: the
  # palette is three on purpose, and a voicemail is raw material the way a
  # chime is. If recordings ever earn their own identity, add the pair here —
  # this map is the entire mechanism.
  @kind_waveform %{
    sound: {"#FF4D1C", "#66210E"},
    recording: {"#FF4D1C", "#66210E"},
    import: {"#1C9BFF", "#0B3E66"},
    music: {"#2FD068", "#135329"}
  }

  defp waveform_colors(kind), do: Map.get(@kind_waveform, kind, {"#FF4D1C", "#66210E"})

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @doc """
  The Studio's actions, rendered by `StatusLive` INTO the home tab bar row —
  inline with the tabs, on the right, the way a DAW puts transport controls in
  the chrome rather than the document.

  This is a function component on purpose: it holds no state, so it can live
  outside the live_component while still driving it. The new-mix form
  addresses the component through a `phx-target` SELECTOR (`#studio-panel`),
  and Import opens the component's hidden file input with a client-side
  `JS.dispatch` — no server round trip, and the picker opens inside the
  user's click gesture, which is what browsers require of it.
  """
  def toolbar(assigns) do
    ~H"""
    <div id="studio-toolbar" class="flex items-center gap-1.5">
      <form
        id="studio-new-mix"
        phx-submit="new_mix"
        phx-target="#studio-panel"
        class="flex items-center gap-1"
      >
        <input
          type="text"
          name="name"
          placeholder="name"
          autocomplete="off"
          aria-label="Name for the new mix"
          class="input input-bordered input-xs w-28 font-mono text-[11px]"
        />
        <button type="submit" class="btn btn-primary btn-xs font-mono uppercase">
          + New mix
        </button>
      </form>

      <button
        type="button"
        phx-click={JS.dispatch("click", to: "#studio-import input[type=file]")}
        class="btn btn-ghost btn-xs border-2 border-base-content/20 font-mono uppercase"
      >
        Import audio
      </button>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `ic-panel` is the house surface, and on the homepage
          (`.ic-home .ic-panel`) it goes translucent with a 10px backdrop blur —
          the same frosted treatment the chat panel gets, so the smoke shader
          reads through the Studio the way it reads through everything else. --%>
    <div id="studio-panel" class="ic-panel flex min-h-0 flex-1 gap-3 overflow-hidden p-3">
      <%!-- Sidebar: everything the studio can open, and the way in. --%>
      <Sidebar.sidebar
        myself={@myself}
        groups={@groups}
        selected={@selected}
        studio_collapsed={@studio_collapsed}
        missing_bundled={@missing_bundled}
        note={@note}
        uploads={@uploads}
        max_entries={max_import_entries()}
      />

      <%!-- The three floating surfaces live in `SoundStudio.Overlays`. They are
            overlays, not layout: each is `fixed` and none participates in the
            arranger's sizing, so moving them changed no class on the surface
            underneath. Their attrs are the whole of what they read. --%>
      <Overlays.context_menu myself={@myself} />
      <Overlays.assign_render_modal myself={@myself} assign_render={@assign_render} />
      <Overlays.info_modal myself={@myself} info={@info} />

      <%!-- Detail: the selected file. --%>
      <section class="flex min-h-0 min-w-0 flex-1 flex-col gap-3 overflow-y-auto">
        <div
          :if={is_nil(@selected)}
          class="flex flex-1 items-center justify-center border-2 border-dashed border-base-content/20 p-8"
        >
          <p class="max-w-prose text-center text-sm text-base-content/60">
            Pick something on the left to open it. Chimes, voicemails, and music
            are all just mix here — anything you select can be trimmed and
            saved back as a sound effect.
          </p>
        </div>

        <%!-- The library manager keeps its own surface; a music track selected
              individually opens in the editor below instead. --%>
        <.live_component
          :if={@selected && @selected.kind == :library}
          module={MusicComponent}
          id="studio-music-library"
          player={@player}
        />

        <Arranger.arranger
          myself={@myself}
          mix={@mix}
          selected={@selected}
          groups={@groups}
          note={@note}
          studio_clip={@studio_clip}
          studio_clipboard={@studio_clipboard}
          studio_undo={@studio_undo}
          studio_redo={@studio_redo}
        />

        <div
          :if={@selected && @selected.kind not in [:library, :mix]}
          class="flex min-h-0 flex-1 flex-col gap-3"
        >
          <header class="flex flex-wrap items-baseline justify-between gap-2">
            <div class="min-w-0">
              <h2 class="truncate text-lg font-bold tracking-tight">{@selected.label}</h2>
              <p class="truncate font-mono text-xs text-base-content/50">{@selected.name}</p>
            </div>
            <%!-- Tinted with the kind's waveform color, so the badge is the
                  legend: a blue wave and a blue "import" badge explain each
                  other. --%>
            <span
              style={"color: #{elem(waveform_colors(@selected.kind), 0)}; border-color: #{elem(waveform_colors(@selected.kind), 0)}66"}
              class="shrink-0 border px-2 py-0.5 font-mono text-[10px] uppercase tracking-widest"
            >
              {@selected.kind}{if @selected.sub && @selected.kind == :sound, do: " · #{@selected.sub}"}
            </span>
          </header>

          <%!-- Waveform. The id is keyed by the source id because AudioClip
                decodes data-src exactly ONCE, at mount — a fixed id would leave
                the first file's wave on screen forever (MUSIC_ROADMAP Phase 5,
                inherited as Part V). --%>
          <div
            id={"studio-trim-#{:erlang.phash2(@selected.id)}"}
            phx-hook="WaveTrim"
            data-duration-ms={@facts && @facts.duration_ms}
            data-from-ms={@studio_trim && @studio_trim.from_ms}
            data-to-ms={@studio_trim && @studio_trim.to_ms}
            class="relative h-28 w-full cursor-crosshair select-none border-2 border-base-content/20"
          >
            <div
              id={"studio-wave-#{:erlang.phash2(@selected.id)}"}
              phx-hook="AudioClip"
              phx-update="ignore"
              data-src={@selected.url}
              data-color-a={elem(waveform_colors(@selected.kind), 0)}
              data-color-b={elem(waveform_colors(@selected.kind), 1)}
              class="pointer-events-none absolute inset-0"
            >
              <canvas data-clip-canvas class="absolute inset-0 h-full w-full"></canvas>
              <div
                data-clip-fallback
                class="absolute inset-x-3 inset-y-8 hidden opacity-30"
                style="background: repeating-linear-gradient(90deg, currentColor 0 2px, transparent 2px 6px);"
              >
              </div>
            </div>

            <%!-- The selection overlay, under `phx-update="ignore"` because the
                  hook owns these inline styles outright — a LiveView patch that
                  reset them mid-drag would snap the selection back to wherever
                  the server last thought it was. --%>
            <div
              id={"studio-ovl-#{:erlang.phash2(@selected.id)}"}
              phx-update="ignore"
              class="pointer-events-none absolute inset-0"
            >
              <div data-trim-shade-l class="absolute inset-y-0 left-0 w-0 bg-base-100/65"></div>
              <div data-trim-shade-r class="absolute inset-y-0 right-0 w-0 bg-base-100/65"></div>
              <div data-trim-edge-a class="absolute inset-y-0 -left-2.5 w-px bg-primary"></div>
              <div data-trim-edge-b class="absolute inset-y-0 -left-2.5 w-px bg-primary"></div>
            </div>
          </div>

          <p class="font-mono text-[10px] text-base-content/40">
            Drag across the waveform to select · click once to clear
          </p>

          <%!-- Served from a route, not a blob — see the moduledoc. The id is
                fixed rather than keyed because the trim hook looks it up to
                scrub; there is only ever one selection open. --%>
          <audio id="studio-audio" controls preload="metadata" src={@selected.url} class="w-full">
          </audio>

          <dl class="grid grid-cols-2 gap-x-4 gap-y-1 font-mono text-xs sm:grid-cols-4">
            <div>
              <dt class="text-base-content/40">Length</dt>
              <dd>{ms(@facts && @facts.duration_ms)}</dd>
            </div>
            <div>
              <dt class="text-base-content/40">Peak</dt>
              <dd>{dbfs(@facts && @facts.peak)}</dd>
            </div>
            <div>
              <dt class="text-base-content/40">Format</dt>
              <dd>
                {if @facts && @facts.rate,
                  do: "#{@facts.rate} Hz · #{@facts.channels} ch",
                  else: "—"}
              </dd>
            </div>
            <div>
              <dt class="text-base-content/40">Size</dt>
              <dd>{MusicComponent.humanize_bytes(@facts && @facts.size)}</dd>
            </div>
          </dl>

          <p :if={@facts && @facts.error} class="font-mono text-xs text-warning">
            {analysis_note(@facts.error)}
          </p>

          <%!-- The tools go here. Named now so the shape of the surface is
                visible and the empty space reads as "next", not "missing". --%>
          <div class="mt-auto border-t-2 border-base-content/20 pt-3">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <p class="font-mono text-[10px] font-bold uppercase tracking-widest text-base-content/40">
                Trim
              </p>
              <p :if={@studio_trim} class="font-mono text-xs text-base-content/60">
                {ms(@studio_trim.from_ms)} → {ms(@studio_trim.to_ms)}
                <span class="text-primary">
                  ({ms(@studio_trim.to_ms - @studio_trim.from_ms)})
                </span>
              </p>
            </div>

            <div :if={@studio_trim} class="mt-2 flex flex-wrap items-center gap-2">
              <button
                type="button"
                phx-click="preview_selection"
                phx-target={@myself}
                class="btn btn-ghost btn-xs font-mono uppercase"
              >
                ▶ Preview
              </button>
              <button
                type="button"
                phx-click="apply_trim"
                phx-target={@myself}
                class="btn btn-primary btn-xs font-mono uppercase"
              >
                Trim to selection
              </button>
              <button
                type="button"
                phx-click="trim_clear"
                class="btn btn-ghost btn-xs font-mono uppercase"
              >
                Clear
              </button>
              <span class="font-mono text-[10px] text-base-content/40">
                Saves a new file in <code>studio/</code> — the original is untouched
              </span>
            </div>

            <p :if={is_nil(@studio_trim)} class="mt-1 text-sm text-base-content/50">
              Drag across the waveform to choose a piece. Fade, normalize, and
              save-as-chime follow.
            </p>

            <p :if={@facts && is_nil(@facts.duration_ms)} class="mt-1 font-mono text-xs text-warning">
              This file's length is unknown, so it can't be trimmed here.
            </p>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
