defmodule BusterClaw.Finance.BLS do
  @moduledoc """
  U.S. Bureau of Labor Statistics public data API — CPI, unemployment, PPI,
  employment, earnings. Free and **keyless**; a free key (email, no card) only
  raises the quotas.

  This is the primary publisher, deliberately. FRED republishes these same
  numbers under its own series ids (`CPIAUCSL` is this API's `CUUR0000SA0`), and
  FRED's terms of use prohibit using its API "in connection with … machine
  learning, including … large language models" and separately prohibit
  "storing, caching, or archiving" its content. Going to BLS gets identical
  figures as a US federal government work with no such clause — which is what
  makes them safe to hand to a model, and safe to cache later.

  Verified against the live API 2026-08-03.

  ## Two things here that will bite a careless caller

  **1. `M13` is not a thirteenth month.** BLS returns the *annual average* as
  period `M13` inside the same `data[]` as the twelve months (and `Q05` as the
  annual for quarterly series). Plotted naively it becomes an extra point at the
  end of every year, sitting at a value no month actually had. It looks
  plausible, it renders crisply, and it is wrong. `observations/2` drops these by
  default and reports how many it dropped; `include_aggregates: true` keeps them,
  flagged with `aggregate: true`.

  **2. A failure arrives as HTTP 200.** BLS signals errors in the *body*
  (`"status" => "REQUEST_NOT_PROCESSED"`), not the status line. A client that
  only checks `status in 200..299` — which is exactly what `Finnhub.get_json/3`
  does — hands the caller an error envelope as success. `get_json/3` here checks
  the body.

  ## Quotas (documented by BLS; not yet hit in anger)

  - **Keyless (v1):** 25 queries/day, 25 series/query, 10 years/request.
  - **Registered (v2):** 500 queries/day, 50 series/query, 20 years/request.

  25 requests a day is a real ceiling for an interactive surface, so
  `daily_quota/0` is stated here rather than discovered when a chart silently
  stops working. Register a key at https://data.bls.gov/registrationEngine/ and
  set `:buster_claw, :bls_api_key`.
  """

  @base "https://api.bls.gov/publicAPI"
  @source "U.S. Bureau of Labor Statistics"
  @source_url "https://www.bls.gov/developers/"

  # Annual/aggregate period codes: M13 for a monthly series, Q05 for quarterly.
  # These share `data[]` with the real observations and are the trap in the
  # moduledoc.
  @aggregate_periods ~w(M13 Q05)

  # BLS series ids are fixed-width alphanumeric codes (CUUR0000SA0,
  # LNS14000000). Validated rather than trusted because the id is interpolated
  # into a URL PATH on the v1 route — a model-supplied string with a slash or a
  # `..` in it would otherwise choose the endpoint, not just the series.
  @series_id_re ~r/\A[A-Z0-9]{1,32}\z/

  # A few series worth naming, so a caller (or a model reading this catalog
  # through `series_catalog/0`) does not have to guess an opaque code. Not
  # exhaustive — any valid id works.
  @known_series %{
    "CUUR0000SA0" => %{
      title: "CPI-U, all items, U.S. city average",
      units: "index 1982-84=100",
      frequency: "monthly"
    },
    "CUUR0000SA0L1E" => %{
      title: "CPI-U, all items less food and energy (core)",
      units: "index 1982-84=100",
      frequency: "monthly"
    },
    "LNS14000000" => %{
      title: "Unemployment rate, 16 years and over, seasonally adjusted",
      units: "percent",
      frequency: "monthly"
    },
    "LNS11300000" => %{
      title: "Labor force participation rate, seasonally adjusted",
      units: "percent",
      frequency: "monthly"
    },
    "CES0000000001" => %{
      title: "Total nonfarm employment, seasonally adjusted",
      units: "thousands of persons",
      frequency: "monthly"
    },
    "WPUFD4" => %{
      title: "PPI, final demand",
      units: "index Nov 2009=100",
      frequency: "monthly"
    }
  }

  @doc "Series ids this module can describe without a lookup. Any valid id still works."
  def series_catalog, do: @known_series

  @doc "Documented queries/day for the current configuration. Informational."
  def daily_quota, do: if(match?({:ok, _key}, api_key()), do: 500, else: 25)

  @doc """
  Observations for one BLS series, oldest first.

  Options:

    * `:start_year` / `:end_year` — inclusive strings or integers. Defaults to
      the last 10 calendar years, which is also the keyless per-request ceiling.
    * `:include_aggregates` — keep `M13`/`Q05` annual rows (default `false`).
      See the moduledoc; the default is what stops a chart growing a phantom
      thirteenth month.
    * `:req_options` — Req overrides (the test seam).

  Returns `{:ok, %{series_id, title, units, frequency, source, source_url,
  as_of, observations, aggregates_dropped, note}}` or `{:error, reason}`.

  Each observation is `%{date: ~D[…], period: "M06", label: "June", value:
  float}`. `date` is the FIRST day of the period — BLS names a month, not a day,
  and inventing the 15th or the last-day would be a precision we were not given.
  """
  def observations(series_id, opts \\ []) do
    with {:ok, id} <- validate_series_id(series_id),
         {:ok, body} <- fetch_series(id, opts) do
      {:ok, build_result(id, body, opts)}
    end
  end

  # --- internals ---

  defp validate_series_id(series_id) do
    id = series_id |> to_string() |> String.trim() |> String.upcase()

    if Regex.match?(@series_id_re, id) do
      {:ok, id}
    else
      {:error, {:invalid_series_id, id}}
    end
  end

  defp build_result(id, body, opts) do
    series = first_series(body)
    {observations, dropped} = parse_observations(series, opts)
    known = Map.get(@known_series, id, %{})
    {requested_from, requested_to} = year_range(opts)

    %{
      series_id: id,
      title: Map.get(known, :title),
      units: Map.get(known, :units),
      frequency: Map.get(known, :frequency),
      source: @source,
      source_url: @source_url,
      as_of: now(),
      observations: observations,
      # What was ASKED for and what actually CAME BACK, side by side. Added after
      # the v1 GET route was caught returning a window nobody requested: a caller
      # that cannot see the delivered span will label a chart with the requested
      # one, and the label will be wrong. Never derive the subtitle from
      # `requested`.
      requested: %{from_year: requested_from, to_year: requested_to},
      covered: covered_range(observations),
      aggregates_dropped: dropped,
      note: aggregates_note(dropped)
    }
  end

  defp covered_range([]), do: nil

  defp covered_range(observations),
    do: %{from: List.first(observations).date, to: List.last(observations).date}

  # Say it in the payload, not only in this module's docs. The count travels
  # with the data so a chart's subtitle can state it, per the roadmap's rule that
  # a bounded fetch never silently looks complete.
  defp aggregates_note(0), do: nil

  defp aggregates_note(count),
    do:
      "#{count} annual-average row(s) (period M13/Q05) were excluded — they are " <>
        "yearly aggregates, not observations of a month."

  defp first_series(body) do
    body
    |> get_in(["Results", "series"])
    |> List.wrap()
    |> List.first()
    |> Kernel.||(%{})
  end

  defp parse_observations(series, opts) do
    include? = Keyword.get(opts, :include_aggregates, false)
    rows = series |> Map.get("data") |> List.wrap()

    {kept, dropped} =
      Enum.reduce(rows, {[], 0}, fn row, {acc, dropped} ->
        aggregate? = Map.get(row, "period") in @aggregate_periods

        if aggregate? and not include? do
          {acc, dropped + 1}
        else
          {maybe_observation(row, aggregate?, acc), dropped}
        end
      end)

    {Enum.sort_by(kept, & &1.date, Date), dropped}
  end

  defp maybe_observation(row, aggregate?, acc) do
    with {:ok, date} <- row_date(row),
         {:ok, value} <- row_value(row) do
      [
        %{
          date: date,
          period: Map.get(row, "period"),
          label: Map.get(row, "periodName"),
          value: value,
          aggregate: aggregate?
        }
        | acc
      ]
    else
      # A row we cannot read is DROPPED, never defaulted. BLS uses "-" for a
      # value it did not publish, and a zero there would draw a cliff into a
      # price index — the same rule `MarketData` enforces on a zero close.
      _unparseable -> acc
    end
  end

  # BLS names a period, not a date. `M06` is June; the observation is filed on
  # the first of the month because that is the only day the source actually
  # implies. Quarterly `Q01`–`Q04` map to the first month of the quarter.
  defp row_date(row) do
    with {year, ""} <- Integer.parse(to_string(Map.get(row, "year"))),
         {:ok, month} <- period_month(Map.get(row, "period")) do
      Date.new(year, month, 1)
    else
      _other -> :error
    end
  end

  defp period_month("M13"), do: {:ok, 1}
  defp period_month("Q05"), do: {:ok, 1}

  defp period_month("M" <> mm) do
    case Integer.parse(mm) do
      {month, ""} when month in 1..12 -> {:ok, month}
      _other -> :error
    end
  end

  defp period_month("Q" <> qq) do
    case Integer.parse(qq) do
      {quarter, ""} when quarter in 1..4 -> {:ok, quarter * 3 - 2}
      _other -> :error
    end
  end

  defp period_month("A" <> _rest), do: {:ok, 1}
  defp period_month(_other), do: :error

  # Values arrive as STRINGS, and "-" means "not published". Parsed strictly:
  # a trailing-garbage value is refused rather than truncated, because
  # `Float.parse("12abc")` happily returns 12.0 and that would be a fabricated
  # figure on a chart.
  defp row_value(row) do
    case row |> Map.get("value") |> to_string() |> String.trim() |> Float.parse() do
      {value, ""} -> {:ok, value}
      _other -> :error
    end
  end

  # Both routes POST, and that is a correction rather than a style choice.
  #
  # The keyless v1 GET route (`/v1/timeseries/data/{id}?startyear=…&endyear=…`)
  # **silently ignores the year params**. Measured 08-03: asking for 2024–2025
  # returned 2024-01 through 2026-06. It answers 200 with a perfectly well-formed
  # body for a window nobody asked for, which is the worst possible failure on a
  # charting surface — the caller believes it bounded the request and the chart
  # shows a different span than its own subtitle claims.
  #
  # v1 POST honours the range keylessly (verified: 2022–2023 returned exactly 24
  # rows), so there is no reason to keep the GET. Posting also moves the series
  # id out of the URL path and into the body, so it can no longer select an
  # endpoint even if `validate_series_id/1` were ever loosened.
  defp fetch_series(id, opts) do
    {start_year, end_year} = year_range(opts)

    {path, extra} =
      case api_key() do
        {:ok, key} -> {"/v2/timeseries/data/", %{registrationkey: key}}
        :error -> {"/v1/timeseries/data/", %{}}
      end

    body =
      Map.merge(extra, %{
        seriesid: [id],
        startyear: to_string(start_year),
        endyear: to_string(end_year)
      })

    base_req(opts)
    |> Keyword.merge(url: @base <> path, json: body)
    |> Req.post()
    |> handle_response()
  end

  defp base_req(opts) do
    opts
    |> Keyword.get(:req_options, [])
    |> Keyword.merge(
      headers: [{"accept", "application/json"}],
      receive_timeout: Keyword.get(opts, :timeout, 15_000),
      retry: false
    )
  end

  # The 200-on-failure guard. BLS puts the verdict in the body; the status line
  # is 200 for a rejected key, an unknown series, and a blown daily quota alike.
  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    case body_status(body) do
      "REQUEST_SUCCEEDED" -> {:ok, body}
      other -> {:error, {:bls_error, other, body_messages(body)}}
    end
  end

  defp handle_response({:ok, %{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp handle_response({:error, reason}), do: {:error, reason}

  defp body_status(body) when is_map(body), do: Map.get(body, "status")
  defp body_status(_body), do: "MALFORMED_RESPONSE"

  defp body_messages(body) when is_map(body), do: body |> Map.get("message") |> List.wrap()
  defp body_messages(_body), do: []

  # Defaults to the last 10 calendar years — the keyless per-request ceiling, so
  # the default request is the largest one that cannot be refused for its span.
  defp year_range(opts) do
    end_year = Keyword.get(opts, :end_year) || Date.utc_today().year
    start_year = Keyword.get(opts, :start_year) || max(1913, to_year(end_year) - 9)
    {to_year(start_year), to_year(end_year)}
  end

  defp to_year(year) when is_integer(year), do: year

  defp to_year(year) do
    case Integer.parse(to_string(year)) do
      {parsed, _rest} -> parsed
      :error -> Date.utc_today().year
    end
  end

  defp api_key do
    case Application.get_env(:buster_claw, :bls_api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _other -> :error
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
