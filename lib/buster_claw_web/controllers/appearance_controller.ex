defmodule BusterClawWeb.AppearanceController do
  @moduledoc """
  Serves a user-uploaded terminal background image (by slot) from the writable
  workspace directory. The bundled `Plug.Static` only serves the read-only
  `priv/static` allowlist, so uploaded assets need their own route. The URL
  carries a cache-busting `?v=` stamp, so a long immutable cache is safe.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Appearance

  def terminal_background(conn, %{"slot" => slot}) do
    with {n, ""} <- Integer.parse(slot),
         path when is_binary(path) <- Appearance.slot_image(n) do
      serve(conn, path)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  def home_background(conn, _params) do
    case Appearance.home_background_image() do
      path when is_binary(path) -> serve(conn, path)
      _ -> send_resp(conn, 404, "")
    end
  end

  defp serve(conn, path) do
    conn
    |> put_resp_header("content-type", Appearance.content_type(path))
    |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
    |> send_file(200, path)
  end
end
