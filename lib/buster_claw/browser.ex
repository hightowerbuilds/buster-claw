defmodule BusterClaw.Browser do
  @moduledoc """
  Browser-rendered fetch boundary.

  Three engines, in falling order of fidelity: the Playwright sidecar (dev
  only), the desktop shell's hidden-webview **live render** (via
  `BusterClaw.Browser.Bridge` — the packaged app's only real-JS path), and
  plain HTTP. `fetch/2` runs the classic sidecar/HTTP pipeline first and
  upgrades to a live render only when the result comes back JS-thin (an SPA
  shell with no readable text) or failed outright (bot-walled) — and only when
  the desktop app is actually attached. `render: :live` forces the live path,
  `render: :off` forbids it.
  """

  alias BusterClaw.Browser.{Bridge, Sidecar}
  alias BusterClaw.Ingest.Content
  alias BusterClaw.URLGuard

  @user_agent "BusterClaw/2.0 BrowserSidecarFallback"
  @max_download_bytes 100_000_000

  def fetch(url, opts \\ []) do
    case URLGuard.validate(url) do
      :ok -> do_fetch(url, opts) |> observe_fetch(url)
      {:error, reason} -> {:error, {:blocked_url, reason}}
    end
  end

  @doc """
  Download a URL's raw bytes (SSRF-guarded), without the markdown conversion
  `fetch/2` does — for capturing binary files (PDF, images, archives, …). Never
  uses the Playwright sidecar (that renders pages). Returns
  `{:ok, %{url, body, content_type, filename}}`.
  """
  def download(url, opts \\ []) do
    case URLGuard.validate(url) do
      :ok -> url |> do_download(opts) |> observe_download(url)
      {:error, reason} -> {:error, {:blocked_url, reason}}
    end
  end

  # A successful fetch pulls untrusted external content in → record it. A
  # live-rendered page carries its engine in the metadata so the audit feed
  # shows the content executed in a (hidden, ephemeral) WebKit view rather
  # than arriving over plain HTTP.
  defp observe_fetch({:ok, page} = result, url) do
    meta = %{url: url, trust: "fetched"}

    meta =
      if Map.get(page, :rendered) == "live", do: Map.put(meta, :via, "live_render"), else: meta

    BusterClaw.Sentinel.observe(:untrusted_ingest, "Browsed #{url}", meta)

    result
  end

  defp observe_fetch(other, _url), do: other

  defp observe_download({:ok, %{body: body}} = result, url) do
    BusterClaw.Sentinel.observe(:untrusted_ingest, "Downloaded #{url}", %{
      url: url,
      trust: "fetched",
      bytes: byte_size(body)
    })

    result
  end

  defp observe_download(other, _url), do: other

  defp do_download(url, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    max_bytes = Keyword.get(opts, :max_bytes, @max_download_bytes)

    request_options =
      [
        headers: [{"user-agent", @user_agent}, {"accept", "*/*"}],
        receive_timeout: timeout,
        retry: false,
        # Stream the body through a running byte cap and abort as soon as it is
        # exceeded, so a hostile/misconfigured host streaming an oversized (or
        # unbounded) response can't OOM the BEAM before a post-hoc size check —
        # peak memory is bounded to ~max_bytes rather than the full body. The
        # collector also gives us the raw bytes exactly as served (streaming
        # skips Req's decode/decompress steps).
        into: download_collector(max_bytes)
      ]
      |> Keyword.merge(Application.get_env(:buster_claw, :browser_req_options, []))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    req =
      [url: url]
      |> Keyword.merge(request_options)
      |> Req.new()
      |> URLGuard.attach()

    case Req.request(req) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        if Req.Response.get_private(resp, :download_too_large, false) do
          {:error, {:too_large, Req.Response.get_private(resp, :downloaded_bytes, 0)}}
        else
          {:ok,
           %{
             url: url,
             body: IO.iodata_to_binary(resp.body),
             content_type: header_value(resp.headers, "content-type"),
             filename: download_filename(url, resp.headers)
           }}
        end

      {:ok, %{status: status}} ->
        {:error, {:bad_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Streaming collector for `download/2`: accumulates raw chunks as iodata while
  # tracking a running total, halting the transfer the moment it crosses
  # `max_bytes`. On halt it flags the response private so the caller returns
  # `{:too_large, bytes}` instead of buffering the whole (potentially unbounded)
  # body first.
  defp download_collector(max_bytes) do
    fn {:data, chunk}, {req, resp} ->
      downloaded = Req.Response.get_private(resp, :downloaded_bytes, 0) + byte_size(chunk)

      resp =
        resp
        |> Map.update!(:body, &[&1, chunk])
        |> Req.Response.put_private(:downloaded_bytes, downloaded)

      if downloaded > max_bytes do
        {:halt, {req, Req.Response.put_private(resp, :download_too_large, true)}}
      else
        {:cont, {req, resp}}
      end
    end
  end

  defp header_value(headers, key) when is_map(headers),
    do: headers |> Map.get(key, []) |> List.first()

  defp header_value(headers, key) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == key, do: v end)
  end

  # Prefer the server-declared filename (Content-Disposition), else the URL's last
  # path segment, else a generic name.
  defp download_filename(url, headers) do
    case content_disposition_filename(header_value(headers, "content-disposition")) do
      name when is_binary(name) and name != "" -> name
      _ -> filename_from_url(url)
    end
  end

  defp content_disposition_filename(nil), do: nil

  defp content_disposition_filename(value) do
    case Regex.run(~r/filename\*?=(?:UTF-8'')?"?([^";]+)"?/i, value) do
      [_, name] -> name |> String.trim() |> URI.decode()
      _ -> nil
    end
  end

  defp filename_from_url(url) do
    path = URI.parse(url).path || ""

    case path |> String.split("/") |> List.last() do
      name when is_binary(name) and name != "" -> URI.decode(name)
      _ -> "download"
    end
  end

  defp do_fetch(url, opts) do
    case live_render_mode(opts) do
      :live ->
        # Forced live render; a failure (no desktop open, load timeout) still
        # degrades to the classic pipeline rather than returning nothing.
        case fetch_with_live_render(url, opts) do
          {:ok, page} -> {:ok, page}
          {:error, _reason} -> classic_fetch(url, opts)
        end

      :off ->
        classic_fetch(url, opts)

      :auto ->
        url |> classic_fetch(opts) |> maybe_live_upgrade(url, opts)
    end
  end

  defp classic_fetch(url, opts) do
    if sidecar_url = sidecar_url(opts) do
      case fetch_with_sidecar(sidecar_url, url, opts) do
        {:ok, page} ->
          {:ok, page}

        {:error, _reason} = error ->
          if Keyword.get(opts, :fallback, true) do
            fetch_with_http(url, opts)
          else
            error
          end
      end
    else
      fetch_with_http(url, opts)
    end
  end

  # The classic pipeline succeeded but extracted almost no readable text — the
  # SPA-shell case (`<div id="root"></div>` plus scripts). A real WebKit render
  # usually recovers the page the visible tab would show.
  defp maybe_live_upgrade({:ok, page} = ok, url, opts) do
    if thin_page?(page) do
      case fetch_with_live_render(url, opts) do
        {:ok, live} -> {:ok, live}
        {:error, _reason} -> ok
      end
    else
      ok
    end
  end

  # A failed plain fetch (bot-walled 403s included) can still succeed in a real
  # WebKit view; keep the original error if the live render can't either.
  defp maybe_live_upgrade({:error, _reason} = error, url, opts) do
    case fetch_with_live_render(url, opts) do
      {:ok, live} -> {:ok, live}
      {:error, _reason} -> error
    end
  end

  # HTML that converted to next-to-no markdown. Non-HTML bodies (JSON APIs,
  # plain text) are never "thin" — a webview wouldn't render them better.
  defp thin_page?(%{html: html, markdown: markdown}) do
    is_binary(html) and String.contains?(html, "<") and
      markdown |> to_string() |> String.trim() |> String.length() < live_render_thin_chars()
  end

  defp thin_page?(_page), do: false

  defp fetch_with_live_render(url, opts) do
    cond do
      not live_render_enabled?() or Keyword.get(opts, :live_render, true) == false ->
        {:error, :live_render_disabled}

      not Bridge.available?() ->
        {:error, :browser_unavailable}

      true ->
        timeout = live_render_timeout_ms()
        # Leave headroom for the settle + read round-trips after the load
        # budget; the Rust side clamps to its own [1s, 20s] window.
        wait_ms = max(timeout - 3_000, 2_000)

        case Bridge.request(:render, %{"url" => url, "wait_ms" => wait_ms}, timeout_ms: timeout) do
          {:ok, %{data: raw}} when is_binary(raw) -> decode_rendered_page(raw, url)
          {:ok, _other} -> {:error, :bad_render_payload}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp decode_rendered_page(raw, url) do
    case Jason.decode(raw) do
      {:ok, %{} = page} ->
        url = presence(page["url"]) || url
        title = presence(page["title"]) || URI.parse(url).host || url

        {:ok,
         %{
           url: url,
           title: title,
           html: "",
           markdown: rendered_markdown(page),
           rendered: "live"
         }}

      _other ->
        {:error, :bad_render_payload}
    end
  end

  # The read script returns rendered innerText + links, not HTML — compose the
  # same readable-markdown shape the classic pipeline produces.
  defp rendered_markdown(page) do
    text = page["text"] |> to_string() |> String.trim()

    links =
      for %{} = link <- List.wrap(page["links"]),
          url = link["url"],
          is_binary(url) and url != "" do
        case link["label"] do
          label when is_binary(label) and label != "" -> "- [#{label}](#{url})"
          _other -> "- #{url}"
        end
      end

    case links do
      [] -> text
      lines -> text <> "\n\n## Links\n\n" <> Enum.join(lines, "\n")
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp live_render_mode(opts) do
    case Keyword.get(opts, :render, :auto) do
      :live -> :live
      :off -> :off
      _other -> :auto
    end
  end

  defp live_render_enabled? do
    Application.get_env(:buster_claw, :browser_live_render_enabled, true)
  end

  defp live_render_timeout_ms do
    Application.get_env(:buster_claw, :browser_live_render_timeout_ms, 15_000)
  end

  defp live_render_thin_chars do
    Application.get_env(:buster_claw, :browser_live_render_thin_chars, 280)
  end

  defp fetch_with_sidecar(sidecar_url, url, opts) do
    timeout = Keyword.get(opts, :timeout, 15_000)

    request_options =
      [
        json: %{
          url: url,
          timeout_ms: timeout,
          browser: Keyword.get(opts, :browser_engine) || Keyword.get(opts, :engine),
          cookies: Keyword.get(opts, :cookies),
          wait_until: Keyword.get(opts, :wait_until, "domcontentloaded")
        },
        receive_timeout: timeout + 1_000,
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:buster_claw, :browser_sidecar_req_options, []))
      |> Keyword.merge(Keyword.get(opts, :sidecar_req_options, []))

    case Req.post(fetch_url(sidecar_url), request_options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        normalize_sidecar_page(body, url)

      {:ok, %{status: status, body: body}} ->
        {:error, {:sidecar_bad_status, status, body}}

      {:error, reason} ->
        {:error, {:sidecar_request_failed, reason}}
    end
  end

  defp fetch_with_http(url, opts) do
    timeout = Keyword.get(opts, :timeout, 15_000)

    request_options =
      [
        headers: [{"user-agent", @user_agent}, {"accept", "text/html,*/*;q=0.8"}],
        receive_timeout: timeout,
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:buster_claw, :browser_req_options, []))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    req =
      [url: url]
      |> Keyword.merge(request_options)
      |> Req.new()
      |> URLGuard.attach()

    case Req.request(req) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        html = to_string(body)

        {:ok,
         %{
           url: url,
           title: Content.html_title(html) || URI.parse(url).host || url,
           html: html,
           markdown: Content.html_to_markdown(html)
         }}

      {:ok, %{status: status}} ->
        {:error, {:bad_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_sidecar_page(%{} = body, fallback_url) do
    html = value(body, ["html", :html]) || ""
    url = value(body, ["url", :url]) || fallback_url

    title =
      value(body, ["title", :title]) || Content.html_title(html) || URI.parse(url).host || url

    markdown = value(body, ["markdown", :markdown]) || Content.html_to_markdown(html, title)

    {:ok, %{url: url, title: title, html: html, markdown: markdown}}
  end

  defp normalize_sidecar_page(body, _fallback_url), do: {:error, {:bad_sidecar_body, body}}

  defp sidecar_url(opts) do
    cond do
      Keyword.get(opts, :use_sidecar, true) == false ->
        nil

      url = Keyword.get(opts, :sidecar_url) ->
        url

      url = Application.get_env(:buster_claw, :browser_sidecar_url) ->
        url

      true ->
        case Sidecar.url() do
          {:ok, url} -> url
          :unavailable -> nil
        end
    end
  end

  defp fetch_url(sidecar_url) do
    sidecar_url
    |> String.trim_trailing("/")
    |> Kernel.<>("/fetch")
  end

  defp value(map, keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end
end
