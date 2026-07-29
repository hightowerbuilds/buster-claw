defmodule BusterClawWeb.TelephonyRecordingController do
  @moduledoc """
  Serves a voicemail recording from the Library to the Message Machine panel's
  `<audio>` player. `/ws/file` rejects binary content and `Plug.Static` only
  serves `priv/static`, so Library audio needs its own route — same posture as
  `AppearanceController`: no pipeline, loopback-only, path-guarded to the
  Library root, audio extensions only.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.FileManager
  alias BusterClaw.Library.Artifact
  alias BusterClawWeb.RangeResponse

  @audio_types %{
    ".mp3" => "audio/mpeg",
    ".m4a" => "audio/mp4",
    ".wav" => "audio/wav",
    ".aiff" => "audio/aiff",
    ".ogg" => "audio/ogg"
  }

  def show(conn, %{"path" => relative}) when is_binary(relative) do
    root = Artifact.root()
    path = Path.expand(Path.join(root, relative))
    content_type = @audio_types[String.downcase(Path.extname(path))]

    if content_type && FileManager.within?(path, root) && File.regular?(path) do
      # Byte ranges via the shared helper (MUSIC_ROADMAP Phase 1). Voicemails
      # are short enough that a whole-file 200 mostly worked, but scrubbing one
      # had the same re-download-from-zero behavior a track does, so the
      # migration fixes it here for free. `immutable` still holds: a recording's
      # path is written once and never rewritten.
      RangeResponse.serve(conn, path,
        content_type: content_type,
        cache_control: "private, max-age=31536000, immutable"
      )
    else
      send_resp(conn, 404, "")
    end
  end

  def show(conn, _params), do: send_resp(conn, 404, "")
end
