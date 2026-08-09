defmodule BusterClawWeb.PocketAssetController do
  @moduledoc """
  Serves one file out of one Pocket.

  The bundled `Plug.Static` only serves the read-only `priv/static` allowlist, so
  operator media needs its own route — the same reason `AppearanceController`
  exists, generalised to any Pocket.

  ## Why this route rather than the workspace one

  `WorkspaceFileController.image/2` already serves anything under `$HOME`, and a
  local Pocket is under the workspace, so for images today this route is
  redundant. It exists because of what comes next: **a mounted Pocket may live
  outside `$HOME` entirely**, and it may hold fonts and documents rather than
  images. Sending every Pocket read through `Pockets.resolve/2` means one fence
  gets audited instead of a widening list of exceptions in a controller that was
  written for a file browser.

  ## Containment

  All of it is `Pockets.resolve/2`'s: a bare filename only, canonicalized and
  re-checked inside the Pocket, `lstat`-ed so a planted symlink is refused rather
  than followed. This controller adds no path handling of its own — deliberately,
  because two places that build paths is how one of them ends up wrong.

  ## Caching

  Revalidation-based (`no-cache` + an ETag of mtime+size), never a long immutable
  `max-age`. Workspace files are shared by every instance and version of the app,
  and by the agent, so the bytes can change under a URL whose `?v=` stamp another
  instance minted. `AppearanceController` records what the immutable strategy cost
  when that happened.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Pockets

  # Types we are willing to name. Anything else is served as a download rather
  # than guessed at — a wrong `content-type` on operator-supplied bytes is how a
  # media folder becomes a script host.
  @content_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".svg" => "image/svg+xml",
    ".woff" => "font/woff",
    ".woff2" => "font/woff2",
    ".ttf" => "font/ttf",
    ".otf" => "font/otf",
    ".mp3" => "audio/mpeg",
    ".wav" => "audio/wav",
    ".txt" => "text/plain; charset=utf-8",
    ".md" => "text/plain; charset=utf-8"
  }

  def show(conn, %{"pocket" => pocket, "file" => file}) do
    case Pockets.resolve(pocket, file) do
      nil -> send_resp(conn, 404, "")
      path -> serve(conn, path)
    end
  end

  def show(conn, _params), do: send_resp(conn, 400, "")

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
          |> put_resp_header("content-type", content_type(path))
          |> put_resp_header("etag", etag)
          |> put_resp_header("cache-control", "private, no-cache")
          # Operator bytes are never sniffed. An `.png` that is actually HTML must
          # not become a document in a same-origin context.
          |> put_resp_header("x-content-type-options", "nosniff")
          |> send_file(200, path)
        end

      _ ->
        send_resp(conn, 404, "")
    end
  end

  defp content_type(path) do
    ext = path |> Path.extname() |> String.downcase()
    Map.get(@content_types, ext, "application/octet-stream")
  end
end
