defmodule BusterClawWeb.VoiceAudioController do
  @moduledoc """
  Plays the operator's voice back to them: reference recordings and rendered
  clips, for the `<audio>` players in Settings → Voice.

  Only `:media` (nosniff) — a media-element request, not HTML, so no `accepts`,
  no session, no CSRF. Loopback-only like every other workspace media route.

  The name is resolved by **allowlist over real directory listings** — a
  recording's basename in `Voice.Reference.dir/0`, a clip's in the manifest, or a
  cache file in `Renderer.cache_dir/0` — and never joined into a path from raw
  input. Same posture as `/notify/sound/:name` and `/music/track/:name`.
  """
  use BusterClawWeb, :controller

  alias BusterClaw.Voice.{Clips, Reference, Renderer}

  def show(conn, %{"name" => name}) do
    case resolve(name) do
      nil ->
        send_resp(conn, 404, "No such voice clip.")

      path ->
        conn
        |> put_resp_header("content-type", "audio/wav")
        |> put_resp_header("cache-control", "private, no-cache")
        |> send_file(200, path)
    end
  end

  defp resolve(name) when is_binary(name) do
    Reference.resolve(name) || Clips.resolve(name) || cached(name)
  end

  # A render-cache file by basename. The cache is content-addressed, so a name is
  # 32 hex characters plus `.wav`; anything else is not a cache file and the
  # listing check would refuse it anyway.
  defp cached(name) do
    with {:ok, names} <- File.ls(Renderer.cache_dir()),
         true <- name in names,
         true <- String.match?(name, ~r/^[a-f0-9]{32}\.wav$/) do
      Path.join(Renderer.cache_dir(), name)
    else
      _ -> nil
    end
  end
end
