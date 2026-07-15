defmodule BusterClaw.Favicons do
  @moduledoc """
  Local favicon fetch + disk cache backing `GET /browser/favicon?host=…`.

  Replaces the Google s2 favicon service the chrome and bookmarks previously
  pointed at — that reported every visited host to a third party, which
  contradicts the app's local-first posture. Icons are fetched from the site
  itself (`https://<host>/favicon.ico`), SSRF-guarded by `BusterClaw.URLGuard`,
  and cached on disk — including misses — so each host is fetched at most once
  per TTL.

  No Sentinel event is recorded here on purpose: the page visit that produced
  the host is already on the audit feed, and favicon lookups are derived
  traffic — observing them would only add noise.
  """

  alias BusterClaw.URLGuard

  @ttl_seconds 7 * 24 * 60 * 60
  @max_bytes 262_144
  @timeout 5_000
  # RFC-1123-ish label chars; the host lands in a filesystem path and a URL, so
  # anything outside this alphabet is rejected outright.
  @host_re ~r/^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$/

  @doc """
  The favicon for `host` as `{:ok, %{body: bytes, content_type: type}}`, or
  `:error` (bad host, blocked by the URL guard, no favicon, or too large).

  Options: `:cache_dir`, `:req_options`, `:ttl_seconds` — all default from the
  `:buster_claw, :favicons` app env (set in test config), then built-ins.
  """
  def fetch(host, opts \\ []) do
    opts = Keyword.merge(Application.get_env(:buster_claw, :favicons, []), opts)

    with host when is_binary(host) <- normalize_host(host),
         :ok <- File.mkdir_p(cache_dir(opts)) do
      case cached(host, opts) do
        {:hit, result} -> result
        :stale -> fetch_and_cache(host, opts)
      end
    else
      _ -> :error
    end
  end

  defp normalize_host(host) when is_binary(host) do
    host = host |> String.trim() |> String.downcase()
    if Regex.match?(@host_re, host), do: host, else: :error
  end

  defp normalize_host(_), do: :error

  defp cache_dir(opts) do
    Keyword.get(opts, :cache_dir, Path.join(BusterClaw.Recovery.data_dir(), "favicon_cache"))
  end

  defp icon_path(host, opts), do: Path.join(cache_dir(opts), host <> ".icon")
  defp type_path(host, opts), do: Path.join(cache_dir(opts), host <> ".type")
  defp miss_path(host, opts), do: Path.join(cache_dir(opts), host <> ".miss")

  defp cached(host, opts) do
    cond do
      fresh?(icon_path(host, opts), opts) ->
        with {:ok, body} <- File.read(icon_path(host, opts)),
             {:ok, type} <- File.read(type_path(host, opts)) do
          {:hit, {:ok, %{body: body, content_type: type}}}
        else
          _ -> :stale
        end

      fresh?(miss_path(host, opts), opts) ->
        {:hit, :error}

      true ->
        :stale
    end
  end

  defp fresh?(path, opts) do
    ttl = Keyword.get(opts, :ttl_seconds, @ttl_seconds)

    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> System.os_time(:second) - mtime < ttl
      _ -> false
    end
  end

  defp fetch_and_cache(host, opts) do
    url = "https://#{host}/favicon.ico"

    with :ok <- URLGuard.validate(url),
         {:ok, %Req.Response{status: 200, body: body} = resp} <- request(url, opts),
         type when is_binary(type) <- image_type(resp),
         true <- is_binary(body) and body != "" and byte_size(body) <= @max_bytes do
      File.write(icon_path(host, opts), body)
      File.write(type_path(host, opts), type)
      File.rm(miss_path(host, opts))
      {:ok, %{body: body, content_type: type}}
    else
      _ ->
        File.write(miss_path(host, opts), "")
        :error
    end
  end

  defp request(url, opts) do
    [
      url: url,
      headers: [{"user-agent", "BusterClaw/2.0 FaviconFetch"}, {"accept", "image/*"}],
      receive_timeout: @timeout,
      retry: false,
      max_redirects: 3,
      decode_body: false
    ]
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Req.new()
    # Re-validate and pin every hop: the up-front validate/1 covers only the
    # first URL, and a favicon fetch follows up to 3 redirects.
    |> URLGuard.attach()
    |> Req.request()
  end

  # Favicons come back as image/* (or octet-stream from lazy servers). Anything
  # else — an HTML 404 page with a 200 status is the classic — is a miss.
  defp image_type(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "content-type") do
      [type | _] ->
        type = type |> String.split(";") |> hd() |> String.trim()

        if String.starts_with?(type, "image/") or type == "application/octet-stream" do
          type
        else
          :error
        end

      _ ->
        :error
    end
  end
end
