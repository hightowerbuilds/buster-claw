defmodule BusterClawWeb.AppearanceController do
  @moduledoc """
  Serves a user-uploaded background image from the shared image pool in the
  writable workspace directory. The bundled `Plug.Static` only serves the
  read-only `priv/static` allowlist, so uploaded assets need their own route.

  One route for one pool: a slot is not owned by a surface, so the same URL backs
  the homepage, the terminal, or both at once.

  Caching is revalidation-based (`no-cache` + an ETag from mtime+size), NOT a
  long immutable max-age: the workspace files are shared by every instance and
  version of the app — and by the agent — so the bytes can change under a URL
  whose `?v=` stamp some other instance minted. Revalidating costs one
  conditional request on 127.0.0.1 (~zero) and can never pin stale bytes; the
  old immutable strategy did exactly that when a past app version replaced
  `home-background.jpg` without this instance's settings stamp changing.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Appearance

  def image(conn, %{"slot" => slot}) do
    with {n, ""} <- Integer.parse(slot),
         path when is_binary(path) <- Appearance.image_path(n) do
      serve(conn, path)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  defp serve(conn, path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} ->
        etag = ~s("#{mtime}-#{size}")

        if etag in get_req_header(conn, "if-none-match") do
          conn
          |> put_resp_header("etag", etag)
          |> put_resp_header("cache-control", "private, no-cache")
          |> send_resp(304, "")
        else
          conn
          |> put_resp_header("content-type", Appearance.content_type(path))
          |> put_resp_header("etag", etag)
          |> put_resp_header("cache-control", "private, no-cache")
          |> send_file(200, path)
        end

      _ ->
        send_resp(conn, 404, "")
    end
  end
end
