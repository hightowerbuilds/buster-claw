defmodule BusterClaw.Weather do
  @moduledoc """
  Current conditions for the home corner widget's Weather tab.

  Backed by Open-Meteo (https://open-meteo.com) — keyless and free, so it fits
  the app's no-API-keys posture the same way DuckDuckGo backs `web_search`. The
  location is set once by the user (the tab has a small form): the query is
  geocoded through Open-Meteo's keyless geocoding API and the winning place is
  stored in `Settings` under `"weather_location"` as JSON.

  Results are cached in `:persistent_term` for `@ttl_ms` (10 min) so an open
  homepage doesn't poll a free service every mount. `req_options` (Req.Test
  plugs) inject in tests; `clear_cache/0` isolates them.
  """

  alias BusterClaw.Settings

  @location_key "weather_location"
  @cache_key {__MODULE__, :cache}
  @ttl_ms :timer.minutes(10)

  @forecast_url "https://api.open-meteo.com/v1/forecast"
  @geocode_url "https://geocoding-api.open-meteo.com/v1/search"

  # WMO weather interpretation codes → human labels.
  @code_labels %{
    0 => "Clear",
    1 => "Mostly clear",
    2 => "Partly cloudy",
    3 => "Overcast",
    45 => "Fog",
    48 => "Freezing fog",
    51 => "Light drizzle",
    53 => "Drizzle",
    55 => "Heavy drizzle",
    56 => "Freezing drizzle",
    57 => "Freezing drizzle",
    61 => "Light rain",
    63 => "Rain",
    65 => "Heavy rain",
    66 => "Freezing rain",
    67 => "Freezing rain",
    71 => "Light snow",
    73 => "Snow",
    75 => "Heavy snow",
    77 => "Snow grains",
    80 => "Light showers",
    81 => "Showers",
    82 => "Violent showers",
    85 => "Snow showers",
    86 => "Snow showers",
    95 => "Thunderstorm",
    96 => "Thunderstorm, hail",
    99 => "Thunderstorm, heavy hail"
  }

  @doc ~S(The stored location, or nil: %{"name" => ..., "lat" => ..., "lon" => ...}.)
  def location do
    with raw when is_binary(raw) <- Settings.get(@location_key),
         {:ok, %{"lat" => _} = loc} <- Jason.decode(raw) do
      loc
    else
      _ -> nil
    end
  end

  @doc """
  Geocode `query` (a city name) and store the first match as the location.
  Returns `{:ok, location}` or `{:error, :not_found | reason}`. Clears the
  conditions cache so the next `current/1` fetches for the new place.
  """
  def set_location(query, opts \\ []) when is_binary(query) do
    params = [name: String.trim(query), count: 1, language: "en", format: "json"]

    case get_json(@geocode_url, params, opts) do
      {:ok, %{"results" => [hit | _]}} ->
        location = %{
          "name" => place_label(hit),
          "lat" => hit["latitude"],
          "lon" => hit["longitude"]
        }

        Settings.put(@location_key, Jason.encode!(location))
        clear_cache()
        {:ok, location}

      {:ok, _no_results} ->
        {:error, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Current conditions for the stored location: `{:ok, conditions}`,
  `{:error, :no_location}` when none is set, or `{:error, reason}` on a fetch
  failure. Served from cache within the TTL.
  """
  def current(opts \\ []) do
    case location() do
      nil -> {:error, :no_location}
      loc -> cached(loc, opts)
    end
  end

  @doc "Drop the cached conditions (tests, and location changes)."
  def clear_cache, do: :persistent_term.erase(@cache_key)

  defp cached(loc, opts) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, nil) do
      {at, %{location: name} = conditions} when now - at < @ttl_ms ->
        if name == loc["name"], do: {:ok, conditions}, else: refetch(loc, opts, now)

      _stale ->
        refetch(loc, opts, now)
    end
  end

  defp refetch(loc, opts, now) do
    with {:ok, conditions} <- fetch(loc, opts) do
      :persistent_term.put(@cache_key, {now, conditions})
      {:ok, conditions}
    end
  end

  defp fetch(loc, opts) do
    params = [
      latitude: loc["lat"],
      longitude: loc["lon"],
      current:
        "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m",
      daily: "temperature_2m_max,temperature_2m_min",
      temperature_unit: "fahrenheit",
      wind_speed_unit: "mph",
      forecast_days: 1,
      timezone: "auto"
    ]

    with {:ok, body} <- get_json(@forecast_url, params, opts) do
      current = body["current"] || %{}
      daily = body["daily"] || %{}
      code = current["weather_code"]

      {:ok,
       %{
         location: loc["name"],
         temp_f: round_num(current["temperature_2m"]),
         feels_like_f: round_num(current["apparent_temperature"]),
         humidity: round_num(current["relative_humidity_2m"]),
         wind_mph: round_num(current["wind_speed_10m"]),
         code: code,
         label: Map.get(@code_labels, code, "—"),
         high_f: round_num(first(daily["temperature_2m_max"])),
         low_f: round_num(first(daily["temperature_2m_min"])),
         fetched_at: DateTime.utc_now(:second)
       }}
    end
  end

  defp get_json(url, params, opts) do
    request =
      Req.new(url: url, params: params, retry: false, receive_timeout: 10_000)
      |> Req.merge(Keyword.get(opts, :req_options, []))

    case Req.get(request) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:weather_status, status, body}}
      {:error, reason} -> {:error, {:weather_request_failed, reason}}
    end
  end

  # "Portland, Oregon" beats bare "Portland" when the admin area is known.
  defp place_label(%{"name" => name} = hit) do
    case hit["admin1"] do
      admin when is_binary(admin) and admin != "" and admin != name -> "#{name}, #{admin}"
      _ -> name
    end
  end

  defp first([head | _rest]), do: head
  defp first(_other), do: nil

  defp round_num(value) when is_number(value), do: round(value)
  defp round_num(_value), do: nil
end
