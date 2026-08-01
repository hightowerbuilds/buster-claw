defmodule BusterClawWeb.StudioFileController do
  @moduledoc """
  Serves audio from `<workspace>/studio/` to the Studio tab's waveform and
  preview player.

  Same posture as the audio routes around it: no pipeline (these are media
  element requests, not HTML), loopback-only, and the name is resolved by
  `SoundStudio.path_for/1` against the real directory listing rather than
  joined from raw input, so there is no traversal surface.

  Goes through `RangeResponse` rather than a bare `send_file` for two reasons:
  imported material can be long enough to scrub through (a voicemail, a whole
  track someone dropped in), and `RangeResponse` sends `nosniff` — which these
  pipeline-less routes otherwise never get, and which matters most exactly here,
  where the bytes are a file the user just handed us.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Notifications.SoundStudio
  alias BusterClawWeb.RangeResponse

  def show(conn, %{"name" => name}) do
    case SoundStudio.path_for(name) do
      nil ->
        send_resp(conn, 404, "")

      path ->
        RangeResponse.serve(conn, path,
          content_type: SoundStudio.content_type(name),
          # Unlike a chime, a studio file can be replaced under the same name by
          # a Finder drop, so this must not be `immutable`.
          cache_control: "private, no-cache"
        )
    end
  end

  def show(conn, _params), do: send_resp(conn, 404, "")
end
