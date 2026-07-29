defmodule BusterClawWeb.MusicController do
  @moduledoc """
  Streams a track from the music library to the dock player's `<audio>` element.

  Same posture as the other media routes — no pipeline (a media element request
  is not an HTML page), loopback-only, content-type from the extension — with
  one addition that matters for anything longer than a chime: byte ranges, via
  `BusterClawWeb.RangeResponse`. See that module for why a whole-file `200` is
  not enough here.

  Request input is never joined into a path. `Music.path_for/1` resolves only
  names that are real entries in the library listing, so an unknown name, a
  non-audio file that happens to sit in the folder, and every traversal shape
  all fall to the same 404.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Music
  alias BusterClawWeb.RangeResponse

  # Not `immutable`: a name is reusable after a delete, so bytes behind a given
  # name can change over the library's lifetime. Not `no-cache` either — that
  # would make every seek re-validate mid-playback. An hour is long enough for a
  # listening session and short enough that a delete-then-re-upload of the same
  # exact filename settles quickly.
  @cache_control "private, max-age=3600"

  def show(conn, %{"name" => name}) when is_binary(name) do
    case Music.path_for(name) do
      nil ->
        send_resp(conn, 404, "")

      path ->
        RangeResponse.serve(conn, path,
          content_type: Music.content_type(path),
          cache_control: @cache_control
        )
    end
  end

  def show(conn, _params), do: send_resp(conn, 404, "")
end
