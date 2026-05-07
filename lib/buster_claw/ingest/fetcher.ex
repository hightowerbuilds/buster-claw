defmodule BusterClaw.Ingest.Fetcher do
  @moduledoc "HTTP fetcher for URL and RSS ingestion."

  alias BusterClaw.Ingest.Content

  @user_agent "BusterClaw/2.0 ElixirRewrite"
  @max_body_bytes 10 * 1024 * 1024
  @retry_statuses [429, 500, 502, 503, 504]

  def fetch(source, opts \\ []) do
    url = Map.fetch!(source, :url)
    type = Map.get(source, :type, "article")
    tags = Map.get(source, :tags, [])
    retries = Keyword.get(opts, :retries, 2)

    with {:ok, body} <- fetch_body(url, retries) do
      items =
        if type == "rss" do
          Content.parse_rss(url, body, tags)
        else
          [Content.parse_article(url, body, tags)]
        end

      {:ok, items}
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
    Req.get(url,
      headers: [
        {"user-agent", @user_agent},
        {"accept",
         "text/html,application/rss+xml,application/atom+xml,application/xml;q=0.9,*/*;q=0.8"}
      ],
      receive_timeout: 30_000,
      retry: false
    )
  end

  defp truncate_body(body) when is_binary(body),
    do: binary_part(body, 0, min(byte_size(body), @max_body_bytes))

  defp truncate_body(body), do: to_string(body)
end
