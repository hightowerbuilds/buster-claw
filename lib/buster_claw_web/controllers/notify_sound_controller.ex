defmodule BusterClawWeb.NotifySoundController do
  @moduledoc """
  Streams the workspace notification chime (`<workspace>/sounds/notify.*`) so the
  `NotifySound` hook can play it when a notification fires. The path is fixed
  (resolved by `Notifications.Sound`, never from request input), so there is no
  traversal surface. 404 when the operator hasn't dropped a sound in.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Notifications.Sound

  def show(conn, _params) do
    case Sound.path() do
      nil ->
        send_resp(conn, 404, "No notification sound. Drop an audio file in <workspace>/sounds/.")

      path ->
        conn
        |> put_resp_header("content-type", Sound.content_type(path))
        |> put_resp_header("cache-control", "private, no-cache")
        |> send_file(200, path)
    end
  end
end
