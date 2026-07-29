defmodule BusterClawWeb.SoundBoardLive do
  @moduledoc """
  The app-wide sound effects player (SOUND_ROADMAP Phase 1).

  Mounted `sticky: true` in the root layout beside `NotifyLive`, so a chime
  rings on whatever page is showing — `/browse`, `/terminal`, none of the home
  tabs. It subscribes to the app's event families and plays the routed sound
  when `BusterClaw.Notifications.SoundBoard` says an event deserves one.

  All policy lives in `SoundBoard` (which event, which key, cooldown) and all
  resolution in `Notifications.Sound` (which file, workspace-over-bundled,
  master switch). This module is the wiring: subscribe, ask, push. The client
  side reuses the `NotifySound` hook unchanged — same unlock dance, same single
  audio element, zero new JS.

  Order of gates per event: mapping → master switch → cooldown. The cooldown
  map is only touched for events that would actually ring, so a silenced app
  doesn't accumulate cooldown state that then eats the first audible chime
  after re-enabling.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.BrowserControl.AgentMode
  alias BusterClaw.Dispatch
  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Notifications.SoundBoard
  alias BusterClaw.Orchestration
  alias BusterClaw.Sentinel
  alias BusterClaw.Telephony

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # One subscriber, six families. Sentinel's topic carries both
      # {:security_event, _} and {:pending_action, _}.
      Sentinel.subscribe()
      Dispatch.subscribe()
      Orchestration.subscribe()
      Telephony.subscribe()
      AgentMode.subscribe_runs()
      SoundBoard.subscribe()
      maybe_boot_chime()
    end

    {:ok, assign(socket, :last_rung, %{}), layout: false}
  end

  # The boot chime (Phase 3): once per BEAM boot, not per page load — the flag
  # is a :persistent_term, so navigation and reconnects never re-ring. Rung
  # through the normal bus so it passes the same enabled/cooldown/resolution
  # gates as everything else. Two windows racing the flag both ring at worst,
  # which is two windows each greeting once. Config-gated off in tests (a
  # global term would make the first root-layout test of every run special).
  #
  # Known, accepted: at real boot the webview has seen no user gesture yet, so
  # the browser may refuse playback and the chime lands silent (roadmap Risk
  # 2). The flag is still set — boot happened, whether or not it was audible.
  defp maybe_boot_chime do
    flag = {BusterClaw.Notifications.SoundBoard, :boot_rung}

    if Application.get_env(:buster_claw, :boot_chime_enabled, true) and
         not :persistent_term.get(flag, false) do
      :persistent_term.put(flag, true)
      SoundBoard.ring("boot")
    end

    :ok
  end

  @impl true
  def handle_info(message, socket) do
    case SoundBoard.event_key(message) do
      nil -> {:noreply, socket}
      key -> {:noreply, maybe_ring(socket, key)}
    end
  end

  defp maybe_ring(socket, key) do
    now = System.monotonic_time(:millisecond)

    with true <- Sound.enabled?(),
         {:ring, last_rung} <- SoundBoard.allow(socket.assigns.last_rung, key, now),
         name when is_binary(name) <- Sound.resolved(key) do
      socket
      |> assign(:last_rung, last_rung)
      |> push_event("notify:play-sound", %{name: name})
    else
      # Switched off, inside the cooldown window, or a key with no sound
      # anywhere (workspace empty and no bundled file) — all the same silence.
      _ -> socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="sound-board" phx-hook="NotifySound"></div>
    """
  end
end
