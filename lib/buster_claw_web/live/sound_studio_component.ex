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

  @doc "Public for `StatusLive`, which selects the mix a render came from."
  def resolve_source(id), do: find_source(groups(), id)

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

  defp find_source(_groups, nil), do: nil

  defp find_source(groups, id) do
    groups |> Enum.flat_map(& &1.items) |> Enum.find(&(&1.id == id))
  end

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

  defp upload_error(:too_large), do: "That file is larger than 100 MB."
  defp upload_error(:not_accepted), do: "Audio files only."
  defp upload_error(:too_many_files), do: "#{@max_import_entries} files at a time, maximum."
  defp upload_error(_other), do: "Upload failed."

  # ---------------------------------------------------------------------------
  # The sidebar's right-click menu
  # ---------------------------------------------------------------------------

  defp menu_item_class,
    do:
      "block w-full whitespace-nowrap px-3 py-1.5 text-left font-mono text-xs hover:bg-base-content/10"

  # `Sound.assign/2` answers `{:ok, _}` / `:ok` depending on the Settings write;
  # only the refusal matters here.
  defp assign_route(key, name) do
    case Sound.assign(key, name) do
      {:error, reason} -> {:error, reason}
      _ok -> :ok
    end
  end

  # A folded group renders no rows at all rather than hiding them with CSS: the
  # rows carry the right-click menu's data attributes, and a hidden row is still
  # a row the menu could open for something you cannot see.
  defp visible_items(group, collapsed) do
    if group.key in collapsed, do: [], else: group.items
  end

  # A real mix file on disk: it has facts worth showing and can become a clip.
  # An arrangement is neither — it is a list of references to these — and the
  # music library manager is not mix at all.
  defp sourceable?(%{path: path}) when is_binary(path), do: true
  defp sourceable?(_item), do: false

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
  defp deletable?(%{kind: :import}), do: true
  defp deletable?(%{kind: :mix}), do: true
  defp deletable?(%{kind: :music}), do: true
  defp deletable?(%{kind: :sound, sub: "yours"}), do: true
  defp deletable?(_item), do: false

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
  defp addable_groups(groups) do
    groups
    |> Enum.reject(&(&1.key == "mix"))
    |> Enum.map(fn group ->
      %{group | items: Enum.reject(group.items, &(&1.kind == :library))}
    end)
    |> Enum.reject(&(&1.items == []))
  end

  # The Studio's track palette: hazard orange stays first, joined by a signal
  # blue and a green in the same saturation family. Three, cycling, for up to
  # eight tracks — a DAW colors tracks so the eye can follow material across
  # the arrangement, and two clips from the same track must read as siblings.
  #
  # The color hangs off the track's LABEL LETTER, not its list position:
  # positions renumber when a middle track is deleted, and a track that
  # changes color because a NEIGHBOR died would break exactly the visual
  # memory the palette exists to serve. Labels are assigned once at creation
  # and never reused while the track lives, so A is always hazard, B always
  # blue, C always green, D hazard again.
  #
  # Inline styles rather than Tailwind classes, deliberately: the clip blocks
  # already carry style= for their geometry, so this adds no new CSP surface,
  # and it spares the JIT-safelist dance that dynamic class names would need.
  @track_palette ["#FF4D1C", "#1C9BFF", "#2FD068"]

  defp track_color(%{label: <<c>>}) when c in ?A..?Z do
    Enum.at(@track_palette, rem(c - ?A, length(@track_palette)))
  end

  # A hand-edited file can carry any label ("?" is the parser's fallback);
  # an unknown one gets the house color rather than a crash.
  defp track_color(_track), do: hd(@track_palette)

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

  # One place computes the arranger's DOM id: the container carries it, and
  # the transport button points at it by data attribute.
  defp arranger_dom_id(%StudioMix{name: name}), do: "studio-arranger-#{:erlang.phash2(name)}"

  # A clip's playable URL, resolved from the catalog at render time — the
  # audition hook fetches THIS, so what it performs is exactly what the
  # sidebar would play. A vanished source resolves to nil and the attribute
  # is simply absent; the transport skips it while Render still refuses.
  defp clip_src(groups, %{source: source}) do
    case find_source(groups, source) do
      %{url: url} -> url
      _ -> nil
    end
  end

  # A clip carries only a source id, so its label is derived rather than stored
  # — renaming nothing, and staying correct if the catalog changes underneath.
  defp clip_label(%{source: source}) do
    source |> String.split(":", parts: 2) |> List.last() |> Path.rootname()
  end

  defp clip_title(%{source: source, start_ms: at, duration_ms: dur}) do
    "#{source} · starts #{ms(at)} · #{ms(dur)} long"
  end

  defp ms(nil), do: "—"
  defp ms(value) when value < 1_000, do: "#{round(value)} ms"
  defp ms(value), do: "#{Float.round(value / 1000, 2)} s"

  defp dbfs(nil), do: "—"
  defp dbfs(peak) when peak <= 0, do: "silent"
  defp dbfs(peak), do: "#{Float.round(20 * :math.log10(peak), 1)} dBFS"

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
      <nav
        class="flex w-56 shrink-0 flex-col gap-3 overflow-y-auto border-r-2 border-base-content/20 pr-2"
        aria-label="Audio sources"
      >
        <div :for={group <- @groups} class="flex flex-col">
          <%!-- The whole heading is the hinge, so the hit target is the width of
                the sidebar rather than a caret. The count stays visible while
                folded — collapsed, it IS the summary: "Music 47". Handled by
                StatusLive (no phx-target), because the collapsed set lives
                there for the same reason the selection does. --%>
          <h3 class="sticky top-0 z-[1] bg-base-100">
            <button
              type="button"
              phx-click="toggle_studio_group"
              phx-value-key={group.key}
              aria-expanded={to_string(group.key not in @studio_collapsed)}
              class="flex w-full items-center gap-1 py-1 text-left font-mono text-[10px] font-bold uppercase tracking-widest text-base-content/40 transition hover:text-base-content/70"
            >
              <span class={[
                "inline-block transition-transform",
                group.key in @studio_collapsed && "-rotate-90"
              ]}>
                ▾
              </span>
              {group.label}
              <span class="text-base-content/25">{length(group.items)}</span>
            </button>
          </h3>

          <p
            :if={group.items == [] and group.key not in @studio_collapsed}
            class="px-1 py-1 font-mono text-[11px] text-base-content/30"
          >
            none yet
          </p>

          <%!-- `aria-current` is a token attribute, not a boolean one: HEEx
                renders `={true}` as a BARE attribute, which is invalid ARIA and
                announces nothing. The explicit string is the contract. --%>
          <button
            :for={item <- visible_items(group, @studio_collapsed)}
            type="button"
            phx-click="select_studio_source"
            phx-value-id={item.id}
            data-studio-source={item.id}
            data-source-label={item.label}
            data-deletable={deletable?(item) && "true"}
            data-sourceable={sourceable?(item) && "true"}
            aria-current={(@selected && @selected.id == item.id && "true") || nil}
            class={[
              "group flex flex-col items-start gap-0 border-l-2 px-2 py-1 text-left transition",
              if(@selected && @selected.id == item.id,
                do: "border-primary bg-primary/10",
                else: "border-transparent hover:border-base-content/30 hover:bg-base-content/5"
              )
            ]}
          >
            <span class="w-full truncate text-sm text-base-content">{item.label}</span>
            <span :if={item.sub} class="w-full truncate font-mono text-[10px] text-base-content/40">
              {item.sub}
            </span>
          </button>
        </div>

        <%!-- The ways in moved up to the tab bar (`toolbar/1`); what remains
              pinned here is the import machinery and its feedback. The file
              input must stay RENDERED for LiveView uploads to work, so it is
              hidden rather than removed — the toolbar's Import button clicks
              it by selector. No phx-submit: auto_upload consumes each file as
              it completes. --%>
        <form
          id="studio-import"
          phx-change="validate_import"
          phx-target={@myself}
          class="sticky bottom-0 flex flex-col gap-1.5 border-t-2 border-base-content/20 bg-base-100/80 pt-2 backdrop-blur"
        >
          <.live_file_input upload={@uploads.import} class="hidden" />

          <p class="font-mono text-[10px] leading-tight text-base-content/40">
            Imports land in <code>studio/</code> in your workspace — you can also
            drop files there in Finder.
          </p>

          <%!-- Offered, never automatic: SOUND_ROADMAP forbids seeding the
                workspace at boot, because a copy that reappears is how "delete
                that sound" becomes a bug report. The operator asking is a
                different act from the app deciding. --%>
          <button
            :if={@missing_bundled > 0}
            type="button"
            phx-click="install_bundled"
            phx-target={@myself}
            class="btn btn-ghost btn-xs w-full justify-start font-mono text-[10px] uppercase"
            title="Copy the built-in chimes into your sounds/ folder so you can edit them"
          >
            ↓ Copy {@missing_bundled} built-in to sounds/
          </button>

          <div :for={entry <- @uploads.import.entries} class="flex items-center gap-1.5">
            <span class="min-w-0 flex-1 truncate font-mono text-[10px] text-base-content/60">
              {entry.client_name}
            </span>
            <progress class="progress progress-primary w-10" value={entry.progress} max="100">
            </progress>
            <button
              type="button"
              phx-click="cancel_import"
              phx-value-ref={entry.ref}
              phx-target={@myself}
              class="font-mono text-[10px] text-base-content/40 hover:text-error"
              aria-label={"Cancel #{entry.client_name}"}
            >
              ✕
            </button>
          </div>

          <p :for={err <- upload_errors(@uploads.import)} class="font-mono text-[10px] text-error">
            {upload_error(err)}
          </p>

          <p
            :for={
              {entry, err} <-
                Enum.flat_map(@uploads.import.entries, fn e ->
                  Enum.map(upload_errors(@uploads.import, e), &{e, &1})
                end)
            }
            class="font-mono text-[10px] text-error"
          >
            {entry.client_name}: {upload_error(err)}
          </p>

          <p
            :if={@note}
            class={[
              "font-mono text-[10px]",
              elem(@note, 0) == :error && "text-error",
              elem(@note, 0) == :info && "text-base-content/60"
            ]}
          >
            {elem(@note, 1)}
          </p>
        </form>
      </nav>

      <%!-- The sidebar's right-click menu. Rendered once, positioned and shown
            by the hook, and under `phx-update="ignore"` because the hook owns
            its text (the armed "Really delete?" state must survive a patch).
            `phx-target` + `pushEventTo(el)` routes delete_source to THIS
            component — Part V landmine 1; without the target it lands on
            StatusLive and crashes. Only sidebar items carrying data-deletable
            summon the menu — the server decides deletability, the hook only
            reads the marker. --%>
      <div
        id="studio-ctx"
        phx-hook="StudioContextMenu"
        phx-target={@myself}
        phx-update="ignore"
        hidden
        class="fixed z-50 min-w-40 border-2 border-base-content/30 bg-base-100 shadow-lg"
      >
        <button type="button" data-ctx-info hidden class={menu_item_class()}>
          Info
        </button>
        <button type="button" data-ctx-rename hidden class={menu_item_class()}>
          Rename
        </button>
        <button type="button" data-ctx-new-mix hidden class={menu_item_class()}>
          Add to new mix
        </button>
        <button type="button" data-ctx-delete hidden class={menu_item_class()}>
          Delete
        </button>
        <%!-- Rename happens in place: the menu becomes the field, Finder-style.
              A modal would be a heavier gesture than the edit deserves, and a
              native prompt() would block the webview's event loop the same way
              confirm() would. The extension is not shown because it is not
              editable — renaming must not be able to turn a .wav into a .txt. --%>
        <input
          type="text"
          data-ctx-rename-input
          hidden
          aria-label="New name"
          autocomplete="off"
          spellcheck="false"
          class="w-full border-0 bg-base-200 px-3 py-1.5 font-mono text-xs focus:outline-none"
        />
      </div>

      <%!-- Assign-on-render. Offered rather than imposed: the render is already
            in the library either way, so "Not now" costs nothing — it just
            means "not routed yet", and Settings → Notify can do it later. --%>
      <div
        :if={@assign_render}
        class="fixed inset-0 z-50"
        phx-window-keydown="close_assign"
        phx-key="escape"
        phx-target={@myself}
      >
        <button
          type="button"
          phx-click="close_assign"
          phx-target={@myself}
          aria-label="Close"
          class="absolute inset-0 h-full w-full bg-black/70 backdrop-blur-sm"
        >
        </button>
        <div class="pointer-events-none absolute inset-0 grid place-items-center p-4">
          <div class="pointer-events-auto w-full max-w-md border-2 border-base-content/30 bg-base-100 shadow-2xl">
            <header class="ic-scanlines relative border-b-2 border-base-content/20 px-5 py-3">
              <p class="ic-eyebrow">Rendered</p>
              <h3 class="truncate font-display text-lg font-black uppercase tracking-tight">
                {Path.rootname(@assign_render)}
              </h3>
            </header>

            <form phx-submit="assign_render" phx-target={@myself} class="space-y-4 p-5">
              <input type="hidden" name="name" value={@assign_render} />

              <div>
                <label
                  for="assign-render-key"
                  class="font-mono text-[10px] font-bold uppercase tracking-widest text-base-content/40"
                >
                  Play it for
                </label>
                <select
                  id="assign-render-key"
                  name="key"
                  class="select select-bordered mt-1 w-full font-mono text-xs"
                >
                  <option :for={{label, key} <- Sound.route_options()} value={key}>{label}</option>
                </select>
              </div>

              <p class="font-mono text-[10px] leading-relaxed text-base-content/40">
                It is already in your sound library — this just points a
                notification at it. The built-in chime is left alone, so you can
                change your mind any time in Settings → Notify.
              </p>

              <div class="flex flex-wrap gap-2">
                <button class="rounded-xs bg-primary px-4 py-2 font-display text-sm font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85">
                  Assign
                </button>
                <button
                  type="button"
                  phx-click="close_assign"
                  phx-target={@myself}
                  class="rounded-xs border-2 border-base-content/20 px-4 py-2 font-mono text-sm transition hover:border-base-content/40"
                >
                  Not now
                </button>
              </div>
            </form>
          </div>
        </div>
      </div>

      <%!-- Info. A modal rather than a bigger menu: a path is long, and the
            point of it is being able to read (and select) the whole thing. --%>
      <div
        :if={@info}
        class="fixed inset-0 z-50"
        phx-window-keydown="close_info"
        phx-key="escape"
        phx-target={@myself}
      >
        <button
          type="button"
          phx-click="close_info"
          phx-target={@myself}
          aria-label="Close info"
          class="absolute inset-0 h-full w-full bg-black/70 backdrop-blur-sm"
        >
        </button>
        <div class="pointer-events-none absolute inset-0 grid place-items-center p-4">
          <div class="pointer-events-auto w-full max-w-lg border-2 border-base-content/30 bg-base-100 shadow-2xl">
            <header class="ic-scanlines relative flex items-center justify-between border-b-2 border-base-content/20 px-5 py-3">
              <div class="relative z-[2] min-w-0">
                <p class="ic-eyebrow">{@info.kind}</p>
                <h3 class="truncate font-display text-lg font-black uppercase tracking-tight">
                  {@info.label}
                </h3>
              </div>
              <button
                type="button"
                phx-click="close_info"
                phx-target={@myself}
                aria-label="Close info"
                class="relative z-[2] grid size-8 shrink-0 place-items-center border-2 border-base-content/30 text-lg leading-none transition hover:border-primary hover:text-primary"
              >
                ×
              </button>
            </header>

            <dl class="space-y-3 p-5 font-mono text-xs">
              <div>
                <dt class="text-base-content/40">On disk</dt>
                <%!-- `select-all` so one click grabs the whole path; `break-all`
                      because a deep workspace path has no spaces to wrap on. --%>
                <dd class="mt-0.5 select-all break-all text-base-content/80">{@info.path}</dd>
              </div>
              <div class="grid grid-cols-3 gap-3">
                <div>
                  <dt class="text-base-content/40">Size</dt>
                  <dd class="mt-0.5">{MusicComponent.humanize_bytes(@info.size)}</dd>
                </div>
                <div>
                  <dt class="text-base-content/40">Length</dt>
                  <dd class="mt-0.5">{ms(@info.duration_ms)}</dd>
                </div>
                <div>
                  <dt class="text-base-content/40">Format</dt>
                  <dd class="mt-0.5">
                    {if @info.rate, do: "#{@info.rate} Hz · #{@info.channels} ch", else: "—"}
                  </dd>
                </div>
              </div>
              <p :if={@info.note} class="text-warning">{@info.note}</p>
            </dl>
          </div>
        </div>
      </div>

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

        <%!-- The arranger. Tracks sum, so a bed on one and hits on another are
              heard together — that is the whole reason tracks exist rather than
              one long row. --%>
        <%!-- The shortcut hook lives HERE, inside the arranger, so the chords
              exist only while an mix is open — nothing binds ⌘Z or ⌘C anywhere
              else in the app. It reads what is actionable off these two data
              attributes rather than guessing, so ⌘C over ordinary page text
              still does what the browser does. --%>
        <div
          :if={@selected && @selected.kind == :mix && @mix}
          id="studio-keys"
          phx-hook="StudioKeys"
          data-clip-selected={to_string(not is_nil(@studio_clip))}
          data-clipboard={to_string(not is_nil(@studio_clipboard))}
          class="flex min-h-0 flex-1 flex-col gap-3"
        >
          <header class="flex flex-wrap items-baseline justify-between gap-2">
            <div class="min-w-0">
              <h2 class="truncate text-lg font-bold tracking-tight">{@mix.name}</h2>
              <p class="font-mono text-xs text-base-content/50">
                {length(@mix.tracks)} {if length(@mix.tracks) == 1, do: "track", else: "tracks"} · {length(
                  StudioMix.clips(@mix)
                )} clips · {ms(StudioMix.duration_ms(@mix))}
              </p>
            </div>
            <div class="flex shrink-0 items-center gap-1">
              <%!-- Undo and redo are buttons as well as shortcuts: a
                    keyboard-only feature is an invisible one, and these also
                    give the state (how deep the stack goes) somewhere to show. --%>
              <button
                type="button"
                phx-click="studio_undo"
                disabled={@studio_undo == []}
                class="btn btn-ghost btn-xs font-mono uppercase disabled:opacity-30"
                title="Undo (⌘Z)"
              >
                ↶ Undo
              </button>
              <button
                type="button"
                phx-click="studio_redo"
                disabled={@studio_redo == []}
                class="btn btn-ghost btn-xs font-mono uppercase disabled:opacity-30"
                title="Redo (⇧⌘Z)"
              >
                ↷ Redo
              </button>
              <%!-- The transport. Keyed by the open mix so switching
                    remounts the hook — destroyed() closes the AudioContext,
                    and a stale score can never keep sounding over a new
                    arrangement. Play is instant and file-less; Render stays
                    the bounce. --%>
              <button
                type="button"
                id={"studio-audition-#{:erlang.phash2(@mix.name)}"}
                phx-hook="StudioAudition"
                data-arranger={arranger_dom_id(@mix)}
                class="btn btn-ghost btn-xs font-mono uppercase"
                title="Hear the arrangement without rendering it"
              >
                ▶ Play
              </button>
              <button
                type="button"
                phx-click="render_mix"
                phx-target={@myself}
                class="btn btn-primary btn-xs font-mono uppercase"
              >
                Render
              </button>
              <button
                type="button"
                phx-click="delete_mix"
                phx-target={@myself}
                data-claw-confirm={"Delete the mix #{@mix.name}? The clips it uses are not touched."}
                class="btn btn-ghost btn-xs font-mono uppercase text-base-content/40 hover:text-error"
              >
                Delete
              </button>
            </div>
          </header>

          <%!-- Add a clip — at the TOP, because it is how a mix starts.
                Everything below it (ruler, tracks, clips) is the result of
                using it, and a control you need first should not be the last
                thing on the page. A plain form rather than drag-from-the-
                sidebar: the sidebar's job is selection, and one control that
                always works beats a gesture that only works from certain
                rows. --%>
          <form
            phx-submit="add_clip"
            phx-target={@myself}
            class="flex flex-wrap items-center gap-2 border-b-2 border-base-content/15 pb-3"
          >
            <label class="font-mono text-[10px] font-bold uppercase tracking-widest text-base-content/40">
              Add clip
            </label>
            <select
              name="source"
              aria-label="Clip source"
              class="select select-bordered select-xs min-w-0 flex-1 font-mono text-[11px]"
            >
              <optgroup :for={group <- addable_groups(@groups)} label={group.label}>
                <option :for={item <- group.items} value={item.id}>{item.label}</option>
              </optgroup>
            </select>
            <select
              name="track"
              aria-label="Destination track"
              class="select select-bordered select-xs font-mono text-[11px]"
            >
              <option :for={track <- @mix.tracks} value={track.id}>Track {track.label}</option>
            </select>
            <button type="submit" class="btn btn-primary btn-xs font-mono uppercase">
              Add
            </button>
          </form>

          <%!-- Ruler. Positions are computed server-side; the hook is told only
                the ruler's length, so the geometry lives in one language. The
                spacer matches the control clusters below — ticks must align
                with the clip REGIONS, which start after the clusters. --%>
          <div class="flex">
            <div class="w-28 shrink-0"></div>
            <div class="relative h-4 min-w-0 flex-1 border-b border-base-content/20">
              <span
                :for={tick <- StudioMix.ticks(StudioMix.view_ms(@mix))}
                style={"left: #{tick.pct}%"}
                class="absolute top-0 -translate-x-1/2 font-mono text-[9px] text-base-content/35"
              >
                {tick.label}
              </span>
            </div>
          </div>

          <%!-- The track stack. Each row is a left control cluster and a clip
                region — the Pro Tools shape, so per-track controls (delete
                now; mute and solo when they come) have a home that grows
                without covering the clips. [data-track] is ONLY the region:
                the drag hook divides pointer X by that rect's width, and a
                row-wide rect would land every drop early by a cluster. --%>
          <div
            id={arranger_dom_id(@mix)}
            phx-hook="TrackArrange"
            phx-target={@myself}
            data-view-ms={StudioMix.view_ms(@mix)}
            class="relative flex select-none flex-col gap-1"
          >
            <%!-- The playhead. Hidden until the transport runs; the hook owns
                  its position outright and re-asserts every frame, so a patch
                  that re-hides it mid-play loses within 16ms. --%>
            <div
              data-playhead
              class="pointer-events-none absolute z-10 hidden w-px bg-base-content/80"
            >
            </div>
            <div :for={track <- @mix.tracks} class="flex items-stretch">
              <div
                style={"border-left-color: #{track_color(track)}"}
                class="flex w-28 shrink-0 flex-col justify-between border-2 border-l-4 border-r-0 border-base-content/15 bg-base-content/[0.06] px-2 py-1"
              >
                <span
                  style={"color: #{track_color(track)}"}
                  class="truncate font-mono text-[10px] font-bold uppercase tracking-wider"
                >
                  Track {track.label}
                </span>
                <div class="flex items-center justify-between gap-1.5">
                  <div class="flex items-center gap-1">
                    <%!-- The DAW pair. M fills neutral (silenced is an absence,
                          not an alarm); S fills the palette green — the one
                          hue that already means "this one sounds". aria-pressed
                          because these are toggles, not actions. --%>
                    <button
                      type="button"
                      phx-click="toggle_mute"
                      phx-value-id={track.id}
                      phx-target={@myself}
                      aria-pressed={to_string(track.muted)}
                      aria-label={"Mute track #{track.label}"}
                      title={"Mute track #{track.label}"}
                      class={[
                        "h-4 w-4 border font-mono text-[9px] font-bold leading-none transition",
                        if(track.muted,
                          do: "border-base-content/60 bg-base-content/70 text-base-100",
                          else:
                            "border-base-content/25 text-base-content/40 hover:border-base-content/50"
                        )
                      ]}
                    >
                      M
                    </button>
                    <button
                      type="button"
                      phx-click="toggle_solo"
                      phx-value-id={track.id}
                      phx-target={@myself}
                      aria-pressed={to_string(track.soloed)}
                      aria-label={"Solo track #{track.label}"}
                      title={"Solo track #{track.label}"}
                      class={[
                        "h-4 w-4 border font-mono text-[9px] font-bold leading-none transition",
                        if(track.soloed,
                          do: "border-[#2FD068] bg-[#2FD068] text-base-100",
                          else:
                            "border-base-content/25 text-base-content/40 hover:border-base-content/50"
                        )
                      ]}
                    >
                      S
                    </button>
                  </div>

                  <button
                    :if={length(@mix.tracks) > 1}
                    type="button"
                    phx-click="remove_track"
                    phx-value-id={track.id}
                    phx-target={@myself}
                    data-claw-confirm={
                      track.clips != [] &&
                        "Delete track #{track.label} and the #{length(track.clips)} clips on it?"
                    }
                    class="font-mono text-[10px] text-base-content/30 transition hover:text-error"
                    aria-label={"Delete track #{track.label}"}
                    title={"Delete track #{track.label}"}
                  >
                    ✕
                  </button>
                </div>
              </div>

              <%!-- A silenced region dims: the arrangement always shows what
                    the mix will contain, whether the silence came from this
                    track's own M or from someone else's S. --%>
              <div
                data-track
                data-track-id={track.id}
                data-audible={to_string(StudioMix.audible?(@mix, track))}
                class={[
                  "relative h-14 min-w-0 flex-1 border-2 border-base-content/15 bg-base-content/[0.03] data-[track-target]:border-primary/60",
                  not StudioMix.audible?(@mix, track) && "opacity-40"
                ]}
              >
                <%!-- Fill and border come from the TRACK (siblings must read
                      as siblings); selection stays the hazard ring, one color
                      for "you are holding this" no matter what it is. The
                      8-digit hex suffixes are alpha: B3 ≈ 70%, 80 = 50%,
                      40 = 25%. --%>
                <div
                  :for={clip <- track.clips}
                  data-clip
                  data-clip-id={clip.id}
                  data-start-ms={clip.start_ms}
                  data-src={clip_src(@groups, clip)}
                  style={"left: #{StudioMix.position_pct(clip.start_ms, StudioMix.view_ms(@mix))}%; width: #{StudioMix.width_pct(clip.duration_ms, StudioMix.view_ms(@mix))}%; border-color: #{track_color(track)}B3; background-color: #{track_color(track)}#{if @studio_clip == clip.id, do: "80", else: "40"}"}
                  class={[
                    "absolute inset-y-2 cursor-grab overflow-hidden rounded-xs border px-1 active:cursor-grabbing",
                    @studio_clip == clip.id && "ring-2 ring-primary"
                  ]}
                  title={clip_title(clip)}
                >
                  <span class="pointer-events-none block truncate font-mono text-[9px] leading-4 text-base-content/80">
                    {clip_label(clip)}
                  </span>
                </div>
              </div>
            </div>

            <%!-- Where a new track appears is where the button sits. Disabled
                  rather than hidden at the cap: a control that vanishes reads
                  as a bug, one that explains itself reads as a limit. --%>
            <button
              type="button"
              phx-click="add_track"
              phx-target={@myself}
              disabled={length(@mix.tracks) >= StudioMix.max_tracks()}
              title={
                if length(@mix.tracks) >= StudioMix.max_tracks(),
                  do: "An mix holds at most #{StudioMix.max_tracks()} tracks",
                  else: "Add a track"
              }
              class="btn btn-ghost btn-xs w-28 justify-start font-mono uppercase disabled:opacity-30"
            >
              + Track
            </button>
          </div>

          <p class="font-mono text-[10px] text-base-content/40">
            Drag clips along a track or between tracks · click one to select it · <kbd>⌘C</kbd>/<kbd>⌘V</kbd> copy and paste ·
            <kbd>⌫</kbd>
            removes · <kbd>⌘Z</kbd>
            undoes
            <span :if={@studio_clipboard} class="text-primary">
              · copied: {@studio_clipboard.source |> String.split(":", parts: 2) |> List.last()}
            </span>
          </p>

          <p
            :if={@note}
            class={[
              "font-mono text-xs",
              elem(@note, 0) == :error && "text-error",
              elem(@note, 0) == :info && "text-base-content/60"
            ]}
          >
            {elem(@note, 1)}
          </p>
        </div>

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
