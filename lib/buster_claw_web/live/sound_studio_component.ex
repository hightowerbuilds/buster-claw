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
       accept: ~w(audio/*),
       max_entries: @max_import_entries,
       max_file_size: @max_import_bytes
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
     |> assign(:facts, analyze(selected))}
  end

  # ---------------------------------------------------------------------------
  # The catalog
  # ---------------------------------------------------------------------------

  @doc "Every source the studio can open, grouped for the sidebar."
  def groups do
    [
      # Imports lead: this is the working material, and it is the one group the
      # operator fills themselves.
      %{key: "imports", label: "Imports", items: import_items()},
      %{key: "sounds", label: "Sounds", items: sound_items()},
      %{key: "recordings", label: "Recordings", items: recording_items()},
      %{key: "music", label: "Music", items: music_items()}
    ]
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
  # Trim
  # ---------------------------------------------------------------------------

  @impl true
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

  def handle_event("import", _params, socket) do
    results =
      consume_uploaded_entries(socket, :import, fn %{path: path}, entry ->
        {:ok, SoundStudio.store(path, entry.client_name)}
      end)

    # Re-read the folder immediately: `update/2` will not fire again on its own,
    # and a successful import that does not appear in the list reads as a failure.
    {:noreply, socket |> assign(:groups, groups()) |> assign(:note, summarize(results))}
  end

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

  # Report per-outcome. A rejected file that does not say WHY is a support
  # question, and "we tried to decode it and could not" is a real answer.
  defp summarize([]), do: {:error, "Choose an audio file first."}

  defp summarize(results) do
    imported = Enum.count(results, &match?({:ok, _}, &1))
    failures = Enum.reject(results, &match?({:ok, _}, &1))

    case {imported, failures} do
      {n, []} -> {:info, "Imported #{n} #{if n == 1, do: "file", else: "files"}."}
      {0, [{:error, reason} | _]} -> {:error, import_error(reason)}
      {n, [_ | _] = all} -> {:error, "Imported #{n}; skipped #{length(all)}."}
    end
  end

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

  defp ms(nil), do: "—"
  defp ms(value) when value < 1_000, do: "#{round(value)} ms"
  defp ms(value), do: "#{Float.round(value / 1000, 2)} s"

  defp dbfs(nil), do: "—"
  defp dbfs(peak) when peak <= 0, do: "silent"
  defp dbfs(peak), do: "#{Float.round(20 * :math.log10(peak), 1)} dBFS"

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `ic-panel` is the house surface, and on the homepage
          (`.ic-home .ic-panel`) it goes translucent with a 10px backdrop blur —
          the same frosted treatment the chat panel gets, so the smoke shader
          reads through the Studio the way it reads through everything else. --%>
    <div class="ic-panel flex min-h-0 flex-1 gap-3 overflow-hidden p-3">
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

        <%!-- The way in. Pinned to the bottom of the sidebar so it stays put as
              the lists above grow. --%>
        <form
          id="studio-import"
          phx-submit="import"
          phx-change="validate_import"
          phx-target={@myself}
          class="sticky bottom-0 mt-auto flex flex-col gap-1.5 border-t-2 border-base-content/20 bg-base-100/80 pt-2 backdrop-blur"
        >
          <.live_file_input
            upload={@uploads.import}
            class="file-input file-input-bordered file-input-xs w-full"
          />
          <button type="submit" class="btn btn-primary btn-xs w-full font-mono uppercase">
            Import audio
          </button>

          <p class="font-mono text-[10px] leading-tight text-base-content/40">
            Lands in <code>studio/</code> in your workspace — you can also drop files
            there in Finder.
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

        <div :if={@selected && @selected.kind != :library} class="flex min-h-0 flex-1 flex-col gap-3">
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
