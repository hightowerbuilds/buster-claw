defmodule BusterClawWeb.BrowserCaptureHook do
  @moduledoc """
  Top-level LiveView bridge for browser co-presence requests.

  Connected (non-embedded) shell views subscribe to `BusterClaw.Browser.Capture`
  and `BusterClaw.Browser.Bridge`. When a capture is requested, they push
  `bc:screenshot_request`; when a co-presence command (current/navigate/open_tab)
  is requested, they push `bc:browser_command`. In both cases the `ScreenshotBridge`
  JS hook invokes the matching Tauri command and POSTs the result back to the
  `/browser/screenshot` or `/browser/command` endpoint.
  """

  alias BusterClaw.Browser.{Bridge, Capture}

  def on_mount(:default, _params, session, socket) do
    if Phoenix.LiveView.connected?(socket) and session["embedded"] != true do
      Capture.subscribe()
      Bridge.subscribe()
    end

    socket =
      Phoenix.LiveView.attach_hook(socket, :browser_capture, :handle_info, fn
        {:capture, ref}, socket ->
          {:halt, Phoenix.LiveView.push_event(socket, "bc:screenshot_request", %{ref: ref})}

        {:browser_command, ref, action, payload}, socket ->
          {:halt,
           Phoenix.LiveView.push_event(socket, "bc:browser_command", %{
             ref: ref,
             action: Atom.to_string(action),
             payload: payload
           })}

        _message, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end
end
