defmodule BusterClaw.Browser do
  @moduledoc "Browser-rendered fetch boundary with an optional supervised Playwright sidecar."

  alias BusterClaw.Ingest.Content
  alias BusterClaw.Browser.Sidecar

  @user_agent "BusterClaw/2.0 BrowserSidecarFallback"

  def fetch(url, opts \\ []) do
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
          error: sidecar_status.error
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

    case Req.get(url, request_options) do
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
