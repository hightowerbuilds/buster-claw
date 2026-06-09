defmodule BusterClawWeb.AppearanceController do
  @moduledoc """
  Serves the user-uploaded terminal background image from the writable workspace
  directory. The bundled `Plug.Static` only serves the read-only `priv/static`
  allowlist, so uploaded assets need their own route. The URL carries a
  cache-busting `?v=` stamp, so a long immutable cache is safe.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Appearance

  def terminal_background(conn, _params) do
    case Appearance.terminal_background() do
      %{path: path} ->
        conn
        |> put_resp_header("content-type", Appearance.content_type(path))
        |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
        |> send_file(200, path)

      nil ->
        send_resp(conn, 404, "")
    end
  end
end
