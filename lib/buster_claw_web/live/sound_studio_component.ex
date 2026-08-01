defmodule BusterClawWeb.SoundStudioComponent do
  @moduledoc """
  The homepage **Studio** sub-tab (SOUND_STUDIO_ROADMAP Phase 3) — every piece
  of audio in the workspace down the left, the selected one open on the right.

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
  alias BusterClaw.Notifications.StudioAudio
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
     |> load_audio(selected)}
  end

  # The open arrangement is read from disk rather than held in the socket, and
  # every mutation writes straight back. That makes Part V landmine 2 a
  # non-issue here for free: a tab switch discards this component, and the audio
  # is exactly where it was because it was never only in memory.
  defp load_audio(socket, %{kind: :audio, name: name}) do
    case StudioAudio.load(name) do
      {:ok, audio} -> assign(socket, :audio, audio)
      {:error, _reason} -> assign(socket, :audio, nil)
    end
  end

  defp load_audio(socket, _selected), do: assign(socket, :audio, nil)

  @doc "Public for `StatusLive`, which selects the audio a render came from."
  def resolve_source(id), do: find_source(groups(), id)

  # ---------------------------------------------------------------------------
  # The catalog
  # ---------------------------------------------------------------------------

  @doc "Every source the studio can open, grouped for the sidebar."
  def groups do
    [
      %{key: "audio", label: "Audio", items: audio_items()},
      # Imports lead the material groups: this is the working audio, and the one
      # the operator fills themselves.
      %{key: "imports", label: "Imports", items: import_items()},
      %{key: "sounds", label: "Sounds", items: sound_items()},
      %{key: "recordings", label: "Recordings", items: recording_items()},
      %{key: "music", label: "Music", items: music_items()}
    ]
  end

  defp audio_items do
    Enum.map(StudioAudio.list(), fn name ->
      %{
        id: "audio:" <> name,
        kind: :audio,
        name: name,
        label: name,
        sub: "arrangement",
        # An audio is not a file the browser can play; it has to be rendered
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
  def handle_event("new_audio", %{"name" => name}, socket) do
    case StudioAudio.create(name) do
      {:ok, created} ->
        send(self(), {:studio_select, "audio:" <> created})
        {:noreply, socket |> assign(:groups, groups()) |> assign(:note, {:info, "New audio."})}

      {:error, :invalid_name} ->
        {:noreply, assign(socket, :note, {:error, "Give the audio a name."})}

      {:error, _reason} ->
        {:noreply, assign(socket, :note, {:error, "Couldn't create that audio."})}
    end
  end

  def handle_event("add_track", _params, socket) do
    {:noreply, save_audio(socket, StudioAudio.add_track(socket.assigns.audio))}
  end

  def handle_event("remove_track", %{"id" => track_id}, socket) do
    {:noreply, save_audio(socket, StudioAudio.remove_track(socket.assigns.audio, track_id))}
  end

  def handle_event("add_clip", %{"source" => source, "track" => track_id}, socket) do
    audio = socket.assigns.audio

    case clip_duration(source) do
      {:ok, duration} ->
        # Land it after whatever is already on that track, so successive adds
        # queue up instead of stacking invisibly at zero.
        at = track_end_ms(audio, track_id)

        {:noreply,
         save_audio(socket, StudioAudio.add_clip(audio, track_id, source, at, duration))}

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
    {:noreply, save_audio(socket, StudioAudio.remove_clip(socket.assigns.audio, clip_id))}
  end

  # Pushed by the TrackArrange hook on drop.
  def handle_event("move_clip", %{"clip_id" => id, "track_id" => track, "start_ms" => at}, socket)
      when is_binary(id) and is_binary(track) and is_number(at) do
    {:noreply, save_audio(socket, StudioAudio.move_clip(socket.assigns.audio, id, track, at))}
  end

  def handle_event("move_clip", _params, socket), do: {:noreply, socket}

  def handle_event("delete_audio", _params, socket) do
    StudioAudio.delete(socket.assigns.audio.name)
    send(self(), {:studio_select, nil})
    {:noreply, socket |> assign(:groups, groups()) |> assign(:note, {:info, "Audio deleted."})}
  end

  def handle_event("render_audio", _params, socket) do
    audio = socket.assigns.audio

    case render_audio(audio) do
      {:ok, name} ->
        send(self(), {:studio_select, "import:" <> name})

        {:noreply,
         socket |> assign(:groups, groups()) |> assign(:note, {:info, "Rendered #{name}."})}

      {:error, reason} ->
        {:noreply, assign(socket, :note, {:error, render_error(reason)})}
    end
  end

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

  defp save_audio(socket, %StudioAudio{} = audio) do
    # Hand the PREVIOUS state up before overwriting it, so undo has somewhere to
    # go. Sending the old state rather than letting the parent re-read it avoids
    # a race where this write has already landed on disk.
    if socket.assigns[:audio], do: send(self(), {:studio_history, socket.assigns.audio})

    StudioAudio.save(audio)
    socket |> assign(:audio, audio) |> assign(:groups, groups())
  end

  defp save_audio(socket, _audio), do: socket

  defp track_end_ms(%StudioAudio{} = audio, track_id) do
    audio.tracks
    |> Enum.find(%{clips: []}, &(&1.id == track_id))
    |> Map.fetch!(:clips)
    |> Enum.map(&(&1.start_ms + &1.duration_ms))
    |> Enum.max(fn -> 0.0 end)
  end

  # A clip caches its source's length for layout. The render re-reads the real
  # file, so a stale cache changes how wide a block draws, never what you hear.
  defp clip_duration(source) do
    with %{path: path} when is_binary(path) <- resolve_source(source),
         {:ok, clip} <- SoundStudio.import_source(path) do
      {:ok, SoundStudio.duration_ms(clip)}
    else
      %{path: nil} -> {:error, :enoent}
      nil -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_audio(%StudioAudio{} = audio) do
    placements =
      audio |> StudioAudio.clips() |> Enum.map(fn {_track, clip} -> placement(clip) end)

    cond do
      placements == [] ->
        {:error, :empty_audio}

      # A clip whose source was deleted or renamed since it was placed. Refuse
      # the whole render rather than quietly dropping it: a mix missing one
      # layer still sounds finished, and you would never know what was lost.
      Enum.any?(placements, &match?({:error, _}, &1)) ->
        {:error, :missing_source}

      true ->
        with {:ok, mixed} <- SoundStudio.mixdown(Enum.map(placements, fn {:ok, p} -> p end)) do
          SoundStudio.save(mixed, audio.name <> "-mix")
        end
    end
  end

  defp placement(clip) do
    with %{path: path} when is_binary(path) <- resolve_source(clip.source),
         {:ok, audio} <- SoundStudio.import_source(path) do
      {:ok, {audio, clip.start_ms}}
    else
      _ -> {:error, clip.source}
    end
  end

  defp render_error(:empty_audio), do: "Add a clip before rendering."
  defp render_error(:missing_source), do: "A clip's source is missing — nothing was rendered."
  defp render_error(:too_long), do: "That arrangement is longer than five minutes."
  defp render_error(:format_mismatch), do: "Those clips don't share a format."
  defp render_error(_other), do: "Couldn't render that audio."

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
        %{size: size, duration_ms: nil, peak: nil, rate: nil, channels: nil, error: :too_large}

      {:error, reason} ->
        %{size: nil, duration_ms: nil, peak: nil, rate: nil, channels: nil, error: reason}
    end
  end

  defp analysis_note(:too_large), do: "Too large to analyse inline."
  defp analysis_note(:no_decoder), do: "The system decoder is unavailable."
  defp analysis_note(:unsupported_source), do: "Couldn't decode this file."
  defp analysis_note(:enoent), do: "That file is gone from disk."
  defp analysis_note(_other), do: "Couldn't read this file."

  # The catalog minus arrangements themselves: an audio cannot contain an
  # audio, and the library manager is not audio at all.
  defp addable_groups(groups) do
    groups
    |> Enum.reject(&(&1.key == "audio"))
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
  outside the live_component while still driving it. The new-audio form
  addresses the component through a `phx-target` SELECTOR (`#studio-panel`),
  and Import opens the component's hidden file input with a client-side
  `JS.dispatch` — no server round trip, and the picker opens inside the
  user's click gesture, which is what browsers require of it.
  """
  def toolbar(assigns) do
    ~H"""
    <div id="studio-toolbar" class="flex items-center gap-1.5">
      <form
        id="studio-new-audio"
        phx-submit="new_audio"
        phx-target="#studio-panel"
        class="flex items-center gap-1"
      >
        <input
          type="text"
          name="name"
          placeholder="name"
          autocomplete="off"
          aria-label="Name for the new audio"
          class="input input-bordered input-xs w-28 font-mono text-[11px]"
        />
        <button type="submit" class="btn btn-primary btn-xs font-mono uppercase">
          + New audio
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
          <h3 class="sticky top-0 bg-base-100 py-1 font-mono text-[10px] font-bold uppercase tracking-widest text-base-content/40">
            {group.label}
            <span class="text-base-content/25">{length(group.items)}</span>
          </h3>

          <p
            :if={group.items == []}
            class="px-1 py-1 font-mono text-[11px] text-base-content/30"
          >
            none yet
          </p>

          <%!-- `aria-current` is a token attribute, not a boolean one: HEEx
                renders `={true}` as a BARE attribute, which is invalid ARIA and
                announces nothing. The explicit string is the contract. --%>
          <button
            :for={item <- group.items}
            type="button"
            phx-click="select_studio_source"
            phx-value-id={item.id}
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

      <%!-- Detail: the selected file. --%>
      <section class="flex min-h-0 min-w-0 flex-1 flex-col gap-3 overflow-y-auto">
        <div
          :if={is_nil(@selected)}
          class="flex flex-1 items-center justify-center border-2 border-dashed border-base-content/20 p-8"
        >
          <p class="max-w-prose text-center text-sm text-base-content/60">
            Pick something on the left to open it. Chimes, voicemails, and music
            are all just audio here — anything you select can be trimmed and
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
              exist only while an audio is open — nothing binds ⌘Z or ⌘C anywhere
              else in the app. It reads what is actionable off these two data
              attributes rather than guessing, so ⌘C over ordinary page text
              still does what the browser does. --%>
        <div
          :if={@selected && @selected.kind == :audio && @audio}
          id="studio-keys"
          phx-hook="StudioKeys"
          data-clip-selected={to_string(not is_nil(@studio_clip))}
          data-clipboard={to_string(not is_nil(@studio_clipboard))}
          class="flex min-h-0 flex-1 flex-col gap-3"
        >
          <header class="flex flex-wrap items-baseline justify-between gap-2">
            <div class="min-w-0">
              <h2 class="truncate text-lg font-bold tracking-tight">{@audio.name}</h2>
              <p class="font-mono text-xs text-base-content/50">
                {length(@audio.tracks)} {if length(@audio.tracks) == 1, do: "track", else: "tracks"} · {length(
                  StudioAudio.clips(@audio)
                )} clips · {ms(StudioAudio.duration_ms(@audio))}
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
              <button
                type="button"
                phx-click="render_audio"
                phx-target={@myself}
                class="btn btn-primary btn-xs font-mono uppercase"
              >
                Render
              </button>
              <button
                type="button"
                phx-click="delete_audio"
                phx-target={@myself}
                data-claw-confirm={"Delete the audio #{@audio.name}? The clips it uses are not touched."}
                class="btn btn-ghost btn-xs font-mono uppercase text-base-content/40 hover:text-error"
              >
                Delete
              </button>
            </div>
          </header>

          <%!-- Ruler. Positions are computed server-side; the hook is told only
                the ruler's length, so the geometry lives in one language. The
                spacer matches the control clusters below — ticks must align
                with the clip REGIONS, which start after the clusters. --%>
          <div class="flex">
            <div class="w-28 shrink-0"></div>
            <div class="relative h-4 min-w-0 flex-1 border-b border-base-content/20">
              <span
                :for={tick <- StudioAudio.ticks(StudioAudio.view_ms(@audio))}
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
            id={"studio-arranger-#{:erlang.phash2(@audio.name)}"}
            phx-hook="TrackArrange"
            phx-target={@myself}
            data-view-ms={StudioAudio.view_ms(@audio)}
            class="flex select-none flex-col gap-1"
          >
            <div :for={track <- @audio.tracks} class="flex items-stretch">
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
                <div class="flex items-center gap-1.5">
                  <button
                    :if={length(@audio.tracks) > 1}
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

              <div
                data-track
                data-track-id={track.id}
                class="relative h-14 min-w-0 flex-1 border-2 border-base-content/15 bg-base-content/[0.03] data-[track-target]:border-primary/60"
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
                  style={"left: #{StudioAudio.position_pct(clip.start_ms, StudioAudio.view_ms(@audio))}%; width: #{StudioAudio.width_pct(clip.duration_ms, StudioAudio.view_ms(@audio))}%; border-color: #{track_color(track)}B3; background-color: #{track_color(track)}#{if @studio_clip == clip.id, do: "80", else: "40"}"}
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
              disabled={length(@audio.tracks) >= StudioAudio.max_tracks()}
              title={
                if length(@audio.tracks) >= StudioAudio.max_tracks(),
                  do: "An audio holds at most #{StudioAudio.max_tracks()} tracks",
                  else: "Add a track"
              }
              class="btn btn-ghost btn-xs w-28 justify-start font-mono uppercase disabled:opacity-30"
            >
              + Track
            </button>
          </div>

          <%!-- Add a clip. A plain form rather than drag-from-the-sidebar: the
                sidebar's job is selection, and one control that always works
                beats a gesture that only works from certain rows. --%>
          <form phx-submit="add_clip" phx-target={@myself} class="flex flex-wrap items-center gap-2">
            <select
              name="source"
              class="select select-bordered select-xs min-w-0 flex-1 font-mono text-[11px]"
            >
              <optgroup :for={group <- addable_groups(@groups)} label={group.label}>
                <option :for={item <- group.items} value={item.id}>{item.label}</option>
              </optgroup>
            </select>
            <select name="track" class="select select-bordered select-xs font-mono text-[11px]">
              <option :for={track <- @audio.tracks} value={track.id}>Track {track.label}</option>
            </select>
            <button type="submit" class="btn btn-ghost btn-xs font-mono uppercase">Add clip</button>
          </form>

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
          :if={@selected && @selected.kind not in [:library, :audio]}
          class="flex min-h-0 flex-1 flex-col gap-3"
        >
          <header class="flex flex-wrap items-baseline justify-between gap-2">
            <div class="min-w-0">
              <h2 class="truncate text-lg font-bold tracking-tight">{@selected.label}</h2>
              <p class="truncate font-mono text-xs text-base-content/50">{@selected.name}</p>
            </div>
            <span class="shrink-0 border border-base-content/20 px-2 py-0.5 font-mono text-[10px] uppercase tracking-widest text-base-content/60">
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
              data-color-a="#ff4d1c"
              data-color-b="#66210e"
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
