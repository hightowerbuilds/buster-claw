defmodule BusterClawWeb.MusicComponent do
  @moduledoc """
  The homepage **Music** sub-tab: the library on disk, and the controls that
  drive the dock player.

  This component **browses and commands**; it does not play. The `<audio>`
  element lives in `BusterClawWeb.MusicPlayerLive`, sticky in the dock, because
  a home tab renders behind `:if` and would destroy its own player on every tab
  switch (MUSIC_ROADMAP Finding 2). So clicking a track here broadcasts a
  command on `Music.Player`'s bus, and the transport shown here is state this
  component was *told*, not state it owns — `StatusLive` subscribes and passes
  it down.

  That split is why "playing" can be true while you are looking at Calendar, and
  why closing this tab does not stop the music.

  ## Uploads

  `allow_upload/3` is configured here rather than on `StatusLive` so the picker
  lives with the surface that uses it. Every accepted entry goes through
  `Music.store/2`, which does the real validation — the picker's `accept` list is
  a client-side convenience and is not trusted.
  """
  use BusterClawWeb, :live_component

  alias BusterClaw.Music
  alias BusterClaw.Music.Player

  # Roadmap Part III: between the notification library's small cap and the
  # workspace importer's 200 MB. A long FLAC clears it; a video does not.
  @max_upload_bytes 100_000_000
  @max_entries 20

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:tracks, [])
     |> assign(:total_bytes, 0)
     |> assign(:flash_note, nil)
     |> assign(:loaded, false)
     |> allow_upload(:track,
       # A MIME wildcard, not `Music.accepted_extensions/0`. LiveView's `:accept`
       # only takes extensions that the `mime` package has a registered type for,
       # and `.m4a` has none — passing the library's own list raises on mount.
       # Registering types in config would work but needs a `mix deps.clean mime
       # --build` to take effect, which is a trap for a fresh clone and CI.
       #
       # Being wider here is also the correct shape: the picker is a client-side
       # convenience, and `Music.store/2` is the gate that actually decides. A
       # file this lets through and the server rejects gets a reason; a file this
       # blocks is one the user cannot even try.
       accept: ~w(audio/*),
       max_entries: @max_entries,
       max_file_size: @max_upload_bytes
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Re-read the folder on first render and whenever the parent pings with a
    # fresh :refresh — the library is a directory the user can also edit in
    # Finder, so it is re-read rather than cached across a session.
    socket =
      if socket.assigns.loaded and not Map.has_key?(assigns, :refresh) do
        socket
      else
        socket |> assign(:loaded, true) |> reload()
      end

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Commands — broadcast, never applied here
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("play", %{"name" => name}, socket) do
    Player.request_play(name)
    {:noreply, socket}
  end

  def handle_event("enqueue", %{"name" => name}, socket) do
    Player.request_enqueue(name)
    {:noreply, socket}
  end

  def handle_event("toggle", _params, socket) do
    Player.request_toggle()
    {:noreply, socket}
  end

  def handle_event("next", _params, socket) do
    Player.request_next()
    {:noreply, socket}
  end

  def handle_event("play_all", _params, socket) do
    case socket.assigns.tracks do
      [] ->
        {:noreply, socket}

      [first | rest] ->
        Player.request_play(first.name)
        Enum.each(rest, &Player.request_enqueue(&1.name))
        {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Library management
  # ---------------------------------------------------------------------------

  def handle_event("delete", %{"name" => name}, socket) do
    case Music.delete(name) do
      :ok ->
        # If the deleted track is the one playing, the player prunes itself on
        # its next transition; nudging it here would race that.
        {:noreply, socket |> reload() |> assign(:flash_note, {:info, "Deleted #{name}."})}

      {:error, _reason} ->
        {:noreply, assign(socket, :flash_note, {:error, "Couldn't delete #{name}."})}
    end
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :track, ref)}
  end

  def handle_event("save", _params, socket) do
    results =
      consume_uploaded_entries(socket, :track, fn %{path: path}, entry ->
        {:ok, Music.store(path, entry.client_name)}
      end)

    {:noreply,
     socket
     |> reload()
     |> assign(:flash_note, summarize(results))}
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp reload(socket) do
    socket
    |> assign(:tracks, Music.tracks())
    |> assign(:total_bytes, Music.total_bytes())
  end

  # Report per-outcome rather than "some uploads failed": a rejected file that
  # does not say WHY is a support question.
  defp summarize([]), do: {:error, "Choose an audio file first."}

  defp summarize(results) do
    stored = Enum.count(results, &match?({:ok, _}, &1))
    failures = Enum.reject(results, &match?({:ok, _}, &1))

    case {stored, failures} do
      {n, []} ->
        {:info, "Added #{n} #{pluralize(n, "track", "tracks")}."}

      {0, [{:error, reason} | _]} ->
        {:error, reason_text(reason)}

      {n, [{:error, reason} | _] = all} ->
        {:error, "Added #{n}; skipped #{length(all)} — #{String.downcase(reason_text(reason))}"}
    end
  end

  defp reason_text(:unsupported_format),
    do: "That format isn't supported (MP3, M4A, AAC, WAV, OGG, FLAC)."

  defp reason_text(:not_audio), do: "That file isn't audio, whatever it is named."
  defp reason_text(:enoent), do: "The upload didn't arrive."
  defp reason_text(_other), do: "Couldn't save that file."

  defp upload_error_text(:too_large), do: "That file is larger than 100 MB."

  defp upload_error_text(:not_accepted),
    do: "Audio files only (MP3, M4A, AAC, WAV, OGG, FLAC)."

  defp upload_error_text(:too_many_files), do: "#{@max_entries} files at a time, maximum."
  defp upload_error_text(_other), do: "Upload failed."

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_n, _singular, plural), do: plural

  @doc false
  def humanize_bytes(nil), do: "—"
  def humanize_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"

  def humanize_bytes(bytes) when bytes < 1_048_576,
    do: "#{Float.round(bytes / 1_024, 1)} KB"

  def humanize_bytes(bytes) when bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  def humanize_bytes(bytes), do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"

  defp playing?(player, name), do: player && player.track == name && player.playing?
  defp loaded?(player, name), do: player && player.track == name
  defp queued?(player, name), do: player && name in player.queue

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 flex-col gap-3">
      <%!-- Header: what the library holds, and the one-click "play everything". --%>
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="font-mono text-xs uppercase tracking-wide text-base-content/60">
          {length(@tracks)} {pluralize(length(@tracks), "track", "tracks")}
          <span :if={@tracks != []} class="text-base-content/40">
            · {humanize_bytes(@total_bytes)}
          </span>
        </div>

        <div :if={@tracks != []} class="flex items-center gap-2">
          <button
            type="button"
            phx-click="play_all"
            phx-target={@myself}
            class="btn btn-ghost btn-xs font-mono uppercase"
          >
            Play all
          </button>
          <button
            :if={@player && @player.track}
            type="button"
            phx-click="toggle"
            phx-target={@myself}
            class="btn btn-ghost btn-xs font-mono uppercase"
          >
            {if @player.playing?, do: "Pause", else: "Resume"}
          </button>
        </div>
      </div>

      <p
        :if={@flash_note}
        class={[
          "font-mono text-xs",
          elem(@flash_note, 0) == :error && "text-error",
          elem(@flash_note, 0) == :info && "text-base-content/60"
        ]}
      >
        {elem(@flash_note, 1)}
      </p>

      <%!-- Empty state: an invitation, not a bug report. It names the folder
            because the library is a real directory the user can also fill from
            Finder. --%>
      <div
        :if={@tracks == []}
        class="flex flex-col items-start gap-2 border-2 border-dashed border-base-content/20 p-6"
      >
        <p class="font-mono text-sm font-bold uppercase tracking-wide">No music yet</p>
        <p class="max-w-prose text-sm text-base-content/70">
          Add audio files below and they land in your workspace under <code class="font-mono text-xs">music/</code>. You can also drop files into that
          folder directly — this is your disk, not a database. Name them
          <code class="font-mono text-xs">Artist - Title.mp3</code>
          and they will be listed that way.
        </p>
      </div>

      <%!-- The library. --%>
      <ul :if={@tracks != []} class="min-h-0 flex-1 divide-y divide-base-content/10 overflow-y-auto">
        <li
          :for={track <- @tracks}
          class={[
            "group flex items-center gap-3 px-1 py-2",
            loaded?(@player, track.name) && "bg-primary/10"
          ]}
        >
          <button
            type="button"
            phx-click="play"
            phx-value-name={track.name}
            phx-target={@myself}
            class="w-5 shrink-0 text-left text-base-content/50 hover:text-primary"
            aria-label={"Play #{track.title}"}
            title="Play now"
          >
            {if playing?(@player, track.name), do: "♪", else: "▶"}
          </button>

          <div class="min-w-0 flex-1">
            <div class="truncate text-sm text-base-content" title={track.name}>
              {track.title}
            </div>
            <div :if={track.artist} class="truncate font-mono text-xs text-base-content/50">
              {track.artist}
            </div>
          </div>

          <span :if={queued?(@player, track.name)} class="font-mono text-xs text-primary">
            queued
          </span>

          <span class="shrink-0 font-mono text-xs text-base-content/40">
            {humanize_bytes(track.size_bytes)}
          </span>

          <button
            type="button"
            phx-click="enqueue"
            phx-value-name={track.name}
            phx-target={@myself}
            class="shrink-0 font-mono text-xs text-base-content/50 opacity-0 transition group-hover:opacity-100 hover:text-primary"
            title="Add to queue"
          >
            +queue
          </button>

          <button
            type="button"
            phx-click="delete"
            phx-value-name={track.name}
            phx-target={@myself}
            data-claw-confirm={"Delete #{track.name} from your workspace?"}
            class="shrink-0 font-mono text-xs text-base-content/40 opacity-0 transition group-hover:opacity-100 hover:text-error"
            title="Delete from the library"
          >
            delete
          </button>
        </li>
      </ul>

      <%!-- Upload. Phase 2's ingest finally gets its picker. --%>
      <form
        id="music-upload"
        phx-submit="save"
        phx-change="validate"
        phx-target={@myself}
        class="flex flex-wrap items-center gap-3 border-t border-base-content/10 pt-3"
      >
        <.live_file_input
          upload={@uploads.track}
          class="file-input file-input-bordered file-input-sm max-w-xs"
        />
        <button type="submit" class="btn btn-primary btn-sm font-mono uppercase">
          Add music
        </button>

        <div :for={entry <- @uploads.track.entries} class="flex items-center gap-2">
          <span class="max-w-40 truncate font-mono text-xs text-base-content/60">
            {entry.client_name}
          </span>
          <progress class="progress progress-primary w-20" value={entry.progress} max="100">
          </progress>
          <button
            type="button"
            phx-click="cancel_upload"
            phx-value-ref={entry.ref}
            phx-target={@myself}
            class="font-mono text-xs text-base-content/40 hover:text-error"
            aria-label="Cancel this upload"
          >
            ✕
          </button>
        </div>

        <p
          :for={err <- upload_errors(@uploads.track)}
          class="w-full font-mono text-xs text-error"
        >
          {upload_error_text(err)}
        </p>

        <p
          :for={
            {entry, err} <-
              Enum.flat_map(@uploads.track.entries, fn e ->
                Enum.map(upload_errors(@uploads.track, e), &{e, &1})
              end)
          }
          class="w-full font-mono text-xs text-error"
        >
          {entry.client_name}: {upload_error_text(err)}
        </p>
      </form>
    </div>
    """
  end
end
