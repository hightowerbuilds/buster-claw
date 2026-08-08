defmodule BusterClawWeb.Status.Weather do
  @moduledoc """
  Homepage conditions, and the sky the weather shader draws from them.

  Two jobs that share one fetch. The Time & Place widget shows conditions; the
  homepage background, when it is on the weather shader, is fed the same
  reading. Both go through `BusterClaw.Weather`'s TTL cache, so a tick is at
  most one request.

  The fetch runs off the LiveView process (`assign_async`-style, resolved in
  `handle_async(:weather, …)` back in `StatusLive`) because a slow weather API
  must never stall the homepage.
  """
  import Phoenix.Component
  import Phoenix.LiveView

  alias BusterClaw.Weather

  # Fetch off the LiveView process; a slow weather API must never stall the
  # homepage. No location yet → show the form instead of spawning a fetch; a
  # loaded map is kept (Weather.current/0 handles staleness via its own TTL).
  def load_weather(socket) do
    cond do
      is_nil(Weather.location()) ->
        assign(socket, :weather_form, true)

      is_map(socket.assigns.weather) ->
        socket

      true ->
        socket
        |> assign(:weather, :loading)
        |> start_async(:weather, fn -> Weather.current() end)
    end
  end

  # On connect, populate the default Time & Place widget tab and, when the
  # background is in weather mode, the sky. Both read the TTL-cached Weather and
  # both would start_async(:weather); the branch keeps exactly one of them from
  # firing so two tasks never race on the same async key. In weather mode
  # `maybe_fetch_sky/1` covers both surfaces (its result also lands in `@weather`
  # via `handle_async/3`); otherwise `load_weather/1` just fills the widget.
  def mount_weather(socket) do
    if socket.assigns.home_bg.mode == "weather" do
      maybe_fetch_sky(socket)
    else
      load_weather(socket)
    end
  end

  # The weather-shader background needs real conditions whether or not the
  # widget's Time & Place tab is open: when the homepage background is in
  # weather mode and a location is set, (re)fetch. Unlike load_weather/1 this
  # refetches even when conditions are already loaded (the :sky_refresh tick),
  # but keeps the loaded map on screen instead of flashing :loading.
  def maybe_fetch_sky(socket) do
    if socket.assigns.home_bg.mode == "weather" and not is_nil(Weather.location()) do
      socket
      |> then(fn s ->
        if is_map(s.assigns.weather), do: s, else: assign(s, :weather, :loading)
      end)
      |> start_async(:weather, fn -> Weather.current() end)
    else
      socket
    end
  end

  # Hand the SmokeBackground hook the real sky: condition code plus wind/cloud,
  # sunrise/sunset as day-fractions, and the location's UTC offset (the hook
  # derives the place's live time-of-day from it each frame). Skipped when the
  # conditions predate the sunrise/sunset fields.
  def push_sky(socket) do
    case socket.assigns.weather do
      %{sunrise_frac: sr, sunset_frac: ss} = w when is_number(sr) and is_number(ss) ->
        push_event(socket, "bc:sky", %{
          code: w.code,
          wind_mph: w.wind_mph,
          cloud_pct: w.cloud_pct,
          sunrise_frac: sr,
          sunset_frac: ss,
          utc_offset: w.utc_offset
        })

      _incomplete ->
        socket
    end
  end
end
