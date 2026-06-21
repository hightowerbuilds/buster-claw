defmodule BusterClawWeb.BrowserCaptureHook do
  @moduledoc """
  Top-level LiveView bridge for browser screenshot requests.

  Connected (non-embedded) shell views subscribe to `BusterClaw.Browser.Capture`
  and, when a capture is requested, push `bc:screenshot_request` to the browser,
  where the `ScreenshotBridge` JS hook invokes the Tauri `browser_screenshot`
  command and POSTs the PNG back to `/browser/screenshot`.
  """

  alias BusterClaw.Browser.Capture

  def on_mount(:default, _params, session, socket) do
    if Phoenix.LiveView.connected?(socket) and session["embedded"] != true do
      Capture.subscribe()
    end

    socket =
      Phoenix.LiveView.attach_hook(socket, :browser_capture, :handle_info, fn
        {:capture, ref}, socket ->
          {:halt, Phoenix.LiveView.push_event(socket, "bc:screenshot_request", %{ref: ref})}

        _message, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end
end
