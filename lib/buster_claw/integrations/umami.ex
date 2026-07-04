defmodule BusterClaw.Integrations.Umami do
  @moduledoc "Umami analytics polling integration."

  @behaviour BusterClaw.Integrations.Service

  alias BusterClaw.Integrations.{Integration, Snapshot}

  @default_period_seconds 24 * 60 * 60
  @metric_types ~w(url referrer country browser os device)

  @impl true
  def fetch(%Integration{} = integration, opts \\ []) do
    with {:ok, website_id} <- required_config(integration, "website_id"),
         {:ok, window} <- window(integration, opts),
         {:ok, stats} <-
           get_json(integration, stats_path(website_id), window_params(window), opts),
         {:ok, metrics} <- fetch_metrics(integration, website_id, window, opts) do
      now = timestamp()
      source_url = source_url(integration, website_id)

      content =
        Snapshot.markdown(integration, %{
          title: "Umami Analytics Snapshot: #{website_id}",
          source: source_url,
          records: metric_records(metrics),
          window:
            "#{DateTime.to_iso8601(window.start_at)} to #{DateTime.to_iso8601(window.end_at)}",
          summary: summary(stats),
          sections: sections(metrics)
        })

      {:ok,
       [
         %{
           date: DateTime.to_date(now),
           filename: Snapshot.filename(integration, "analytics", now),
           source_url: source_url,
           name: "Umami Analytics Snapshot: #{website_id}",
           tags: ["integration", "umami", "analytics", "monitoring"],
           content: content,
           fetched_at: now
         }
       ]}
    end
  end

  @impl true
  def verify_webhook(_integration, _headers, _body), do: {:error, :webhooks_not_supported}

  @impl true
  def normalize_webhook(_integration, _body), do: {:error, :webhooks_not_supported}

  defp fetch_metrics(integration, website_id, window, opts) do
    metrics =
      @metric_types
      |> Enum.reduce_while({:ok, %{}}, fn type, {:ok, acc} ->
        params = Keyword.put(window_params(window), :type, type)

        case get_json(integration, metrics_path(website_id), params, opts) do
          {:ok, body} -> {:cont, {:ok, Map.put(acc, type, List.wrap(body))}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    metrics
  end

  defp get_json(integration, path, params, opts) do
    req_options =
      opts
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(
        url: endpoint(integration, path),
        params: params,
        headers: headers(integration),
        receive_timeout: Keyword.get(opts, :timeout, 15_000),
        retry: false
      )

    case Req.get(req_options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 429} = resp} ->
        {:error, {:rate_limited, 429, retry_after(resp)}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Surface a 429 distinctly (with any numeric Retry-After seconds) so callers
  # can back off instead of treating it as an opaque http_error. HTTP-date
  # Retry-After values fall back to nil.
  defp retry_after(resp) do
    case Req.Response.get_header(resp, "retry-after") do
      [value | _] ->
        case Integer.parse(to_string(value)) do
          {seconds, _rest} when seconds >= 0 -> seconds
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp summary(stats) do
    [
      "Pageviews: #{stat(stats, "pageviews")}",
      "Visitors: #{stat(stats, "visitors")}",
      "Visits: #{stat(stats, "visits")}",
      "Bounce rate: #{stat(stats, "bounces")}",
      "Average visit duration: #{stat(stats, "totaltime")}"
    ]
  end

  defp sections(metrics) do
    Enum.flat_map(@metric_types, fn type ->
      [
        "",
        "## #{metric_title(type)}",
        "",
        metric_rows(Map.get(metrics, type, []))
      ]
    end)
  end

  defp metric_rows([]), do: ["- No records returned."]

  defp metric_rows(rows) do
    rows
    |> Enum.take(10)
    |> Enum.map(fn row ->
      label =
        row_value(row, ["x", "url", "referrer", "country", "browser", "os", "device", "name"])

      count = row_value(row, ["y", "value", "visitors", "pageviews", "count"])
      "- #{Snapshot.value(label)}: #{Snapshot.value(count)}"
    end)
  end

  defp metric_records(metrics) do
    metrics
    |> Map.values()
    |> Enum.map(&length/1)
    |> Enum.sum()
  end

  defp stat(stats, key) do
    stats
    |> row_value([key, "#{key}_value", "total_#{key}"])
    |> Snapshot.value()
  end

  defp row_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, known_atom_key(key))
    end)
  end

  defp row_value(_value, _keys), do: nil

  defp known_atom_key("pageviews"), do: :pageviews
  defp known_atom_key("pageviews_value"), do: :pageviews_value
  defp known_atom_key("total_pageviews"), do: :total_pageviews
  defp known_atom_key("visitors"), do: :visitors
  defp known_atom_key("visitors_value"), do: :visitors_value
  defp known_atom_key("total_visitors"), do: :total_visitors
  defp known_atom_key("visits"), do: :visits
  defp known_atom_key("visits_value"), do: :visits_value
  defp known_atom_key("total_visits"), do: :total_visits
  defp known_atom_key("bounces"), do: :bounces
  defp known_atom_key("bounces_value"), do: :bounces_value
  defp known_atom_key("total_bounces"), do: :total_bounces
  defp known_atom_key("totaltime"), do: :totaltime
  defp known_atom_key("totaltime_value"), do: :totaltime_value
  defp known_atom_key("total_totaltime"), do: :total_totaltime
  defp known_atom_key("x"), do: :x
  defp known_atom_key("url"), do: :url
  defp known_atom_key("referrer"), do: :referrer
  defp known_atom_key("country"), do: :country
  defp known_atom_key("browser"), do: :browser
  defp known_atom_key("os"), do: :os
  defp known_atom_key("device"), do: :device
  defp known_atom_key("name"), do: :name
  defp known_atom_key("y"), do: :y
  defp known_atom_key("value"), do: :value
  defp known_atom_key("count"), do: :count
  defp known_atom_key(_key), do: nil

  defp required_config(%Integration{config: config}, key) do
    case Map.get(config || %{}, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_config, key}}
    end
  end

  defp window(integration, opts) do
    config = integration.config || %{}
    now = Keyword.get(opts, :now, timestamp())
    end_at = parse_datetime(Map.get(config, "end_at")) || now

    start_at =
      parse_datetime(Map.get(config, "start_at")) ||
        DateTime.add(end_at, -period_seconds(Map.get(config, "period")), :second)

    {:ok, %{start_at: start_at, end_at: end_at}}
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp period_seconds("1h"), do: 60 * 60
  defp period_seconds("24h"), do: @default_period_seconds
  defp period_seconds("7d"), do: 7 * @default_period_seconds
  defp period_seconds("30d"), do: 30 * @default_period_seconds
  defp period_seconds(value) when is_integer(value) and value > 0, do: value
  defp period_seconds(_value), do: @default_period_seconds

  defp window_params(window) do
    [
      startAt: DateTime.to_unix(window.start_at, :millisecond),
      endAt: DateTime.to_unix(window.end_at, :millisecond)
    ]
  end

  defp stats_path(website_id), do: "/api/websites/#{URI.encode_www_form(website_id)}/stats"
  defp metrics_path(website_id), do: "/api/websites/#{URI.encode_www_form(website_id)}/metrics"

  defp source_url(integration, website_id) do
    endpoint(integration, "/websites/#{URI.encode_www_form(website_id)}")
  end

  defp endpoint(%Integration{base_url: base_url}, path) do
    String.trim_trailing(to_string(base_url), "/") <> path
  end

  defp headers(%Integration{token: token}) when is_binary(token) and token != "" do
    [{"authorization", "Bearer #{token}"}, {"accept", "application/json"}]
  end

  defp headers(_integration), do: [{"accept", "application/json"}]

  defp metric_title("url"), do: "Top Pages"
  defp metric_title("referrer"), do: "Referrers"
  defp metric_title("country"), do: "Countries"
  defp metric_title("browser"), do: "Browsers"
  defp metric_title("os"), do: "Operating Systems"
  defp metric_title("device"), do: "Devices"
  defp metric_title(type), do: String.capitalize(type)

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
