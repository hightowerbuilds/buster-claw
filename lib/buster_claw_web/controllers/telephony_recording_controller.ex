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
      conn
      |> put_resp_header("content-type", content_type)
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> send_file(200, path)
    else
      send_resp(conn, 404, "")
    end
  end

  def show(conn, _params), do: send_resp(conn, 404, "")
end
