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
    case fetch_icon("https://#{host}/favicon.ico", opts) || discover_and_fetch(host, opts) do
      %{body: body, content_type: type} ->
        File.write(icon_path(host, opts), body)
        File.write(type_path(host, opts), type)
        File.rm(miss_path(host, opts))
        {:ok, %{body: body, content_type: type}}

      nil ->
        File.write(miss_path(host, opts), "")
        :error
    end
  end

  # One icon-URL attempt: URLGuard-vetted GET that must come back an image
  # within the size cap. Returns the icon map or `nil` so attempts chain
  # with `||`.
  defp fetch_icon(url, opts) do
    with :ok <- URLGuard.validate(url),
         {:ok, %Req.Response{status: 200, body: body} = resp} <- request(url, opts),
         type when is_binary(type) <- image_type(resp),
         true <- is_binary(body) and body != "" and byte_size(body) <= @max_bytes do
      %{body: body, content_type: type}
    else
      _miss -> nil
    end
  end

  # Modern sites often skip /favicon.ico entirely and declare their icon via
  # <link rel="icon" href=…> — when the well-known path misses, fetch the site
  # root (bounded) and follow the first declared icon instead. The resolved
  # href goes through the same URLGuard-vetted fetch, so a hostile page can't
  # point the favicon fetcher at metadata/loopback addresses.
  defp discover_and_fetch(host, opts) do
    case declared_icon_url(host, opts) do
      nil -> nil
      url -> fetch_icon(url, opts)
    end
  end

  defp declared_icon_url(host, opts) do
    base = "https://#{host}/"

    with :ok <- URLGuard.validate(base),
         {:ok, %Req.Response{status: 200, body: body}} <- request_html(base, opts),
         href when is_binary(href) <- icon_href(to_string(body)) do
      resolve_icon_href(base, href)
    else
      _miss -> nil
    end
  end

  # rel tokens that mark a link tag as an icon declaration. Plain "icon"
  # (incl. "shortcut icon") beats apple-touch variants, which are oversized
  # home-screen art.
  @icon_rels ~w(icon apple-touch-icon apple-touch-icon-precomposed)

  defp icon_href(html) do
    html = String.slice(html, 0, 300_000)

    candidates =
      for [tag] <- Regex.scan(~r/<link\b[^>]*>/i, html),
          rel = tag_attr(tag, "rel"),
          href = tag_attr(tag, "href"),
          is_binary(rel) and is_binary(href) and href != "",
          tokens = rel |> String.downcase() |> String.split(),
          Enum.any?(tokens, &(&1 in @icon_rels)) do
        {tokens, href}
      end

    case Enum.find(candidates, fn {tokens, _href} -> "icon" in tokens end) ||
           List.first(candidates) do
      {_tokens, href} -> href
      nil -> nil
    end
  end

  defp tag_attr(tag, name) do
    case Regex.run(~r/\b#{name}\s*=\s*["']([^"']*)["']/i, tag) do
      [_, value] -> String.replace(value, "&amp;", "&")
      _no_match -> nil
    end
  end

  defp resolve_icon_href(base, href) do
    href = String.trim(href)

    if String.starts_with?(href, "data:") do
      nil
    else
      resolved = base |> URI.merge(href) |> URI.to_string()

      case URI.parse(resolved).scheme do
        scheme when scheme in ["http", "https"] -> resolved
        _other -> nil
      end
    end
  end

  defp request_html(url, opts) do
    [
      url: url,
      headers: [{"user-agent", "BusterClaw/2.0 FaviconFetch"}, {"accept", "text/html"}],
      receive_timeout: @timeout,
      retry: false,
      max_redirects: 3,
      decode_body: false
    ]
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Req.new()
    |> URLGuard.attach()
    |> Req.request()
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
