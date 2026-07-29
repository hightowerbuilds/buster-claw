defmodule BusterClawWeb.MusicPlayerLive do
  @moduledoc """
  The dock music player.

  Mounted `sticky: true` in `Layouts.app` beside `DockLive`, which is the whole
  point: a sticky LiveView keeps its process *and its DOM* across live
  navigation, so a track started on the homepage keeps playing while you switch
  to Chat, open `/browse`, and come back. An `<audio>` element inside the Music
  tab would be destroyed the moment the tab's `:if` went false — see
  MUSIC_ROADMAP Finding 2.

  ## Division of labour

  * `BusterClaw.Music.Player` owns the transport rules as pure transitions.
    This module applies them and renders; it holds no logic of its own.
  * The `<audio>` element is `phx-update="ignore"` and belongs to the
    `MusicPlayer` hook. LiveView must never patch it — re-writing `src` on an
    unrelated re-render restarts playback, which is the classic way a player
    like this "randomly jumps to the start".
  * The client reports what actually happened (playing, paused, ended, position,
    duration). The element is the source of truth for playback; the server is
    the source of truth for *what should be playing next*.

  ## Known limits

  * `/split` renders through `Layouts.bare/1`, which has no dock, so playback
    does not survive entering split view. Accepted (roadmap Finding 2).
  * A full page reload remounts this LiveView and playback stops. Sticky
    survives navigation, not reloads.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Music
  alias BusterClaw.Music.Player

  # Matches the hook's reporting throttle; see music_player.js.
  @position_report_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Player.subscribe_commands()

    socket =
      socket
      |> assign(:player, Player.new())
      |> assign(:report_ms, @position_report_ms)

    {:ok, socket, layout: false}
  end

  # --- Commands from anywhere (the Music tab, a future command verb) ---

  @impl true
  def handle_info({:music_command, message}, socket) do
    {:noreply, update_player(socket, &Player.apply_command(&1, message))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # --- Reports from the element ---

  @impl true
  def handle_event("ended", _params, socket) do
    # Deliberately the same transition as "next", so a track finishing and a
    # user clicking forward cannot behave differently.
    {:noreply, update_player(socket, &Player.advance/1)}
  end

  def handle_event("position", %{"seconds" => seconds}, socket) do
    # Not announced: a position tick every few seconds would wake every
    # subscribed LiveView for a number that only this player's own readout uses
    # between real transitions.
    {:noreply, assign(socket, :player, Player.report_position(socket.assigns.player, seconds))}
  end

  def handle_event("duration", %{"seconds" => seconds}, socket) do
    {:noreply, update_player(socket, &Player.report_duration(&1, seconds))}
  end

  def handle_event("playing", %{"playing" => playing?}, socket) do
    {:noreply, update_player(socket, &Player.report_playing(&1, playing?))}
  end

  def handle_event("error", _params, socket) do
    # The file went away or will not decode. `fail_current/1` records the name
    # for the Music tab ("couldn't play X — skipped"), advances, and removes
    # the bad track from history so previous/1 cannot bounce back onto it. The
    # queue is finite and only shrinks, so a whole shelf of bad files drains
    # instead of looping.
    {:noreply, update_player(socket, &Player.fail_current/1)}
  end

  # --- Controls in the dock itself ---

  def handle_event("toggle", _params, socket),
    do: {:noreply, update_player(socket, &Player.toggle/1)}

  def handle_event("next", _params, socket),
    do: {:noreply, update_player(socket, &Player.advance/1)}

  def handle_event("previous", _params, socket),
    do: {:noreply, update_player(socket, &Player.previous/1)}

  def handle_event("stop", _params, socket),
    do: {:noreply, update_player(socket, &Player.stop/1)}

  def handle_event("volume", %{"value" => value}, socket) do
    {:noreply, update_player(socket, &Player.set_volume(&1, to_number(value)))}
  end

  def handle_event("seek", %{"value" => value}, socket),
    do: {:noreply, update_player(socket, &Player.seek(&1, to_number(value)))}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Every transition goes through here so nothing can change state without the
  # rest of the app hearing about it, and so a deleted file can never strand the
  # queue.
  defp update_player(socket, fun) do
    player =
      socket.assigns.player
      |> fun.()
      |> Player.prune(Music.list())
      |> Player.announce()

    assign(socket, :player, player)
  end

  defp to_number(value) when is_number(value), do: value

  defp to_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  defp to_number(_value), do: 0

  defp label(nil), do: nil

  defp label(name) do
    info = Music.track_info(name)
    if info.artist, do: "#{info.artist} — #{info.title}", else: info.title
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="bc-music-player"
      phx-hook="MusicPlayer"
      data-src={@player.track && ~p"/music/track/#{@player.track}"}
      data-playing={to_string(@player.playing?)}
      data-volume={@player.volume}
      data-seek-id={@player.seek_id}
      data-seek-to={@player.seek_to}
      data-report-ms={@report_ms}
      class="flex shrink-0 items-center gap-2 font-mono text-xs text-base-content/70"
    >
      <%!-- The element the hook owns. phx-update="ignore" is load-bearing: a
            LiveView patch that rewrites src restarts playback. --%>
      <audio id="bc-music-audio" phx-update="ignore" preload="metadata"></audio>

      <%!-- Idle means nothing at all in the dock. An empty transport with dead
            buttons reads as broken; DockLive stays quiet without weather for
            the same reason. --%>
      <div :if={not Player.idle?(@player)} class="flex items-center gap-1.5">
        <button
          type="button"
          phx-click="previous"
          disabled={@player.history == []}
          title="Previous"
          class="px-1 disabled:opacity-30"
          aria-label="Previous track"
        >
          ⏮
        </button>

        <button
          type="button"
          phx-click="toggle"
          title={if @player.playing?, do: "Pause", else: "Play"}
          class="px-1"
          aria-label={if @player.playing?, do: "Pause", else: "Play"}
        >
          {if @player.playing?, do: "⏸", else: "▶"}
        </button>

        <button
          type="button"
          phx-click="next"
          disabled={@player.queue == []}
          title="Next"
          class="px-1 disabled:opacity-30"
          aria-label="Next track"
        >
          ⏭
        </button>

        <span
          :if={@player.track}
          class="max-w-48 truncate text-base-content/80"
          title={label(@player.track)}
        >
          {label(@player.track)}
        </span>

        <span :if={@player.queue != []} class="text-base-content/50" title="Tracks queued">
          +{length(@player.queue)}
        </span>
      </div>
    </div>
    """
  end
end
