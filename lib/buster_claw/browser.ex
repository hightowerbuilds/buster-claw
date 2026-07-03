defmodule BusterClaw.Browser do
  @moduledoc "Browser-rendered fetch boundary with an optional supervised Playwright sidecar."

  alias BusterClaw.Ingest.Content
  alias BusterClaw.Browser.Sidecar
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

  # A successful fetch pulls untrusted external content in → record it.
  defp observe_fetch({:ok, _page} = result, url) do
    BusterClaw.Sentinel.observe(:untrusted_ingest, "Browsed #{url}", %{url: url, trust: "fetched"})

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
        # Raw bytes — never let Req decode JSON/gzip into a term; we want the file
        # exactly as served.
        decode_body: false
      ]
      |> Keyword.merge(Application.get_env(:buster_claw, :browser_req_options, []))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    req =
      [url: url]
      |> Keyword.merge(request_options)
      |> Req.new()
      |> Req.Request.append_request_steps(ssrf_guard: &URLGuard.req_step/1)

    case Req.request(req) do
      {:ok, %{status: status, headers: headers, body: body}} when status in 200..299 ->
        bytes = IO.iodata_to_binary(body)

        if byte_size(bytes) > max_bytes do
          {:error, {:too_large, byte_size(bytes)}}
        else
          {:ok,
           %{
             url: url,
             body: bytes,
             content_type: header_value(headers, "content-type"),
             filename: download_filename(url, headers)
           }}
        end

      {:ok, %{status: status}} ->
        {:error, {:bad_status, status}}

      {:error, reason} ->
        {:error, reason}
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

  def status do
    sidecar_status = Sidecar.status()
    configured_url = Application.get_env(:buster_claw, :browser_sidecar_url)

    cond do
      is_binary(configured_url) ->
        %{mode: "sidecar", sidecar: "configured", health: "available", url: configured_url}

      sidecar_status.enabled ->
        %{
          mode: "sidecar",
          sidecar: sidecar_status.health,
          health: sidecar_status.health,
          url: sidecar_status.url,
          error: sidecar_status.error,
          sandbox: sidecar_status.sandbox
        }

      true ->
        %{
          mode: "http-fallback",
          sidecar: "not-started",
          health: "available"
        }
    end
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
      |> Req.Request.append_request_steps(ssrf_guard: &URLGuard.req_step/1)

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
