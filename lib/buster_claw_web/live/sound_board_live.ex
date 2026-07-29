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
    end

    {:ok, assign(socket, :last_rung, %{}), layout: false}
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
