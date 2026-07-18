defmodule BusterClawWeb.NotifySoundController do
  @moduledoc """
  Streams notification sounds from the workspace library (`<workspace>/sounds/`).

  `show/2` serves the resolved fallback chime; `named/2` serves a specific
  library file for per-event playback and Settings → Notify previews. Neither
  joins request input into a path: `show` uses the fixed resolution in
  `Notifications.Sound`, and `named` only resolves names that `Sound.path_for/1`
  finds as real directory entries — so there is no traversal surface. 404 when
  the library is empty or the name is unknown.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Notifications.Sound

  def show(conn, _params) do
    serve(conn, Sound.path())
  end

  def named(conn, %{"name" => name}) do
    serve(conn, Sound.path_for(name))
  end

  defp serve(conn, nil) do
    send_resp(conn, 404, "No notification sound. Drop an audio file in <workspace>/sounds/.")
  end

  defp serve(conn, path) do
    conn
    |> put_resp_header("content-type", Sound.content_type(path))
    |> put_resp_header("cache-control", "private, no-cache")
    |> send_file(200, path)
  end
end
