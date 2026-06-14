defmodule BusterClaw.Finance.Finnhub do
  @moduledoc """
  Finnhub client — quotes + company news. Key-gated: reads
  `:buster_claw, :finnhub_api_key` (wired from the `FINNHUB_API_KEY` env var in
  `config/runtime.exs`). When no key is configured every call returns
  `{:error, :not_configured}` so callers degrade gracefully instead of hitting
  the API tokenless.

  Free-tier US-equity quotes are typically ~15 minutes delayed; results carry an
  `as_of` timestamp and a delay note so a digest never presents a stale price as
  live. Every result carries `source` + `as_of` (provenance by construction).
  """

  @base "https://finnhub.io/api/v1"
  @news_lookback_days 7
  @news_limit 10

  @doc "Latest quote for a ticker symbol."
  def quote(symbol, opts \\ []) do
    sym = normalize(symbol)

    with {:ok, key} <- api_key(),
         {:ok, body} <- get_json("/quote", [symbol: sym, token: key], opts) do
      {:ok,
       %{
         symbol: sym,
         source: "Finnhub",
         source_url: "https://finnhub.io/",
         as_of: quote_as_of(body),
         price: body["c"],
         change: body["d"],
         percent_change: body["dp"],
         high: body["h"],
         low: body["l"],
         open: body["o"],
         previous_close: body["pc"],
         note: "Free-tier US-equity quotes may be ~15 minutes delayed."
       }}
    end
  end

  @doc "Recent company news for a ticker symbol."
  def news(symbol, opts \\ []) do
    sym = normalize(symbol)
    {from, to} = news_range(opts)
    limit = Keyword.get(opts, :limit, @news_limit)

    with {:ok, key} <- api_key(),
         {:ok, body} <-
           get_json("/company-news", [symbol: sym, from: from, to: to, token: key], opts) do
      {:ok,
       %{
         symbol: sym,
         source: "Finnhub",
         source_url: "https://finnhub.io/",
         as_of: now(),
         range: %{from: from, to: to},
         articles: body |> List.wrap() |> Enum.take(limit) |> Enum.map(&news_item/1)
       }}
    end
  end

  # --- internals ---

  defp news_item(item) when is_map(item) do
    %{
      headline: item["headline"],
      summary: item["summary"],
      url: item["url"],
      source: item["source"],
      as_of: unix_to_iso(item["datetime"])
    }
  end

  defp news_item(_item), do: %{headline: nil, summary: nil, url: nil, source: nil, as_of: nil}

  defp news_range(opts) do
    to = Keyword.get(opts, :to) || Date.utc_today()
    from = Keyword.get(opts, :from) || Date.add(to, -@news_lookback_days)
    {Date.to_iso8601(from), Date.to_iso8601(to)}
  end

  defp quote_as_of(%{"t" => t}), do: unix_to_iso(t) || now()
  defp quote_as_of(_body), do: now()

  defp unix_to_iso(seconds) when is_integer(seconds) and seconds > 0 do
    case DateTime.from_unix(seconds) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end

  defp unix_to_iso(_seconds), do: nil

  defp api_key do
    case Application.get_env(:buster_claw, :finnhub_api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :not_configured}
    end
  end

  defp get_json(path, params, opts) do
    req_options =
      opts
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(
        url: @base <> path,
        params: params,
        headers: [{"accept", "application/json"}],
        receive_timeout: Keyword.get(opts, :timeout, 15_000),
        retry: false
      )

    case Req.get(req_options) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(symbol), do: symbol |> to_string() |> String.trim() |> String.upcase()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
