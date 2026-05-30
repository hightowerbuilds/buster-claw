defmodule BusterClaw.Ingest.Fetcher do
  @moduledoc "HTTP fetcher for URL and RSS ingestion."

  alias BusterClaw.Browser
  alias BusterClaw.Ingest.Content
  alias BusterClaw.URLGuard

  @user_agent "BusterClaw/2.0 ElixirRewrite"
  @max_body_bytes 10 * 1024 * 1024
  @retry_statuses [429, 500, 502, 503, 504]

  def fetch(source, opts \\ []) do
    url = Map.fetch!(source, :url)

    case URLGuard.validate(url) do
      :ok -> do_fetch(source, url, opts)
      {:error, reason} -> {:error, {:blocked_url, reason}}
    end
  end

  defp do_fetch(source, url, opts) do
    type = Map.get(source, :type, "article")
    tags = Map.get(source, :tags, [])
    retries = Keyword.get(opts, :retries, 2)

    case type do
      "browser" ->
        fetch_browser(source, opts)

      "rss" ->
        with {:ok, body} <- fetch_body(url, retries) do
          {:ok, Content.parse_rss(url, body, tags)}
        end

      _ ->
        with {:ok, body} <- fetch_body(url, retries) do
          {:ok, [Content.parse_article(url, body, tags)]}
        end
    end
  end

  defp fetch_browser(source, opts) do
    url = Map.fetch!(source, :url)
    tags = Map.get(source, :tags, [])

    browser_opts =
      opts
      |> Keyword.put(:browser_engine, Map.get(source, :browser_engine))
      |> Keyword.put(:cookies, Map.get(source, :cookies))

    with {:ok, page} <- Browser.fetch(url, browser_opts) do
      {:ok,
       [
         %{
           url: page.url,
           title: page.title,
           content: page.markdown,
           tags: tags
         }
       ]}
    end
  end

  defp fetch_body(url, retries) do
    request(url)
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, truncate_body(body)}

      {:ok, %{status: status}} when status in @retry_statuses and retries > 0 ->
        fetch_body(url, retries - 1)

      {:ok, %{status: status}} ->
        {:error, {:bad_status, status}}

      {:error, _reason} when retries > 0 ->
        fetch_body(url, retries - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(url) do
    [
      url: url,
      headers: [
        {"user-agent", @user_agent},
        {"accept",
         "text/html,application/rss+xml,application/atom+xml,application/xml;q=0.9,*/*;q=0.8"}
      ],
      receive_timeout: 30_000,
      retry: false
    ]
    |> Keyword.merge(Application.get_env(:buster_claw, :ingest_req_options, []))
    |> Req.new()
    |> Req.Request.append_request_steps(ssrf_guard: &URLGuard.req_step/1)
    |> Req.request()
  end

  defp truncate_body(body) when is_binary(body),
    do: binary_part(body, 0, min(byte_size(body), @max_body_bytes))

  defp truncate_body(body), do: to_string(body)
end
