defmodule BusterClawWeb.SketchAssetController do
  @moduledoc """
  Serves one image out of one sketch's sidecar.

  `SKETCH_ROADMAP` Phase 4. The bundled `Plug.Static` only serves the read-only
  `priv/static` allowlist, so workspace media needs its own route — the same
  reason `AppearanceController` and `PocketAssetController` exist.

  ## Containment is `Sketch.Assets.resolve/2`'s, and this adds none of its own

  A name must be sixteen hex digits and a known extension — the shape `Assets`
  mints and nothing else. That is an allowlist, not a traversal check: no input
  shaped like `../` matches it, so there is nothing to strip and no second place
  building paths. Two places that build paths is how one of them ends up wrong.

  ## Immutable caching, which is normally the wrong answer here

  `PocketAssetController` deliberately revalidates, because a workspace file can
  change under a URL when the operator or the agent rewrites it — and it records
  what the immutable strategy cost when that happened.

  **This route is the exception, and for a reason rather than by preference: the
  filename is a hash of the content.** Different bytes are a different URL, so a
  cached response can never be stale. Content-addressing is precisely the
  condition under which `immutable` is correct, and a sketch re-rendering on
  every stroke would otherwise re-request every image on the page.

  The media type comes from `Assets`, which read it out of the file's own header
  rather than its extension — so this cannot be talked into announcing the wrong
  one by a file that was named to lie.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Sketch.Assets

  def show(conn, %{"sketch" => sketch, "file" => file}) do
    case Assets.resolve(sketch, file) do
      {:ok, path, media_type} -> serve(conn, path, media_type)
      {:error, _reason} -> send_resp(conn, 404, "")
    end
  end

  def show(conn, _params), do: send_resp(conn, 400, "")

  defp serve(conn, path, media_type) do
    conn
    |> put_resp_header("content-type", media_type)
    |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
    # Operator bytes are never sniffed. The type above was read from the header,
    # but nosniff is what stops a browser from overriding it anyway.
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_file(200, path)
  end
end
