defmodule BusterClaw.WeatherTest do
  use BusterClaw.DataCase

  alias BusterClaw.Weather

  setup do
    Weather.clear_cache()
    on_exit(fn -> Weather.clear_cache() end)
    Req.Test.verify_on_exit!()
    :ok
  end

  defp opts, do: [req_options: [plug: {Req.Test, __MODULE__}]]

  defp stub_geocode(results) do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/search"
      Req.Test.json(conn, %{"results" => results})
    end)
  end

  defp forecast_body do
    %{
      "current" => %{
        "temperature_2m" => 71.6,
        "apparent_temperature" => 69.8,
        "relative_humidity_2m" => 54,
        "weather_code" => 2,
        "wind_speed_10m" => 7.3
      },
      "daily" => %{
        "temperature_2m_max" => [78.1],
        "temperature_2m_min" => [55.9]
      }
    }
  end

  defp put_location do
    BusterClaw.Settings.put(
      "weather_location",
      Jason.encode!(%{"name" => "Portland, Oregon", "lat" => 45.52, "lon" => -122.68})
    )
  end

  test "set_location geocodes and stores the first match" do
    stub_geocode([
      %{"name" => "Portland", "admin1" => "Oregon", "latitude" => 45.52, "longitude" => -122.68}
    ])

    assert {:ok, %{"name" => "Portland, Oregon", "lat" => 45.52}} =
             Weather.set_location("portland", opts())

    assert %{"name" => "Portland, Oregon"} = Weather.location()
  end

  test "set_location reports a geocode miss" do
    stub_geocode([])
    assert {:error, :not_found} = Weather.set_location("xyzzyville", opts())
    assert Weather.location() == nil
  end

  test "current with no location set" do
    assert {:error, :no_location} = Weather.current(opts())
  end

  test "current fetches, shapes, and rounds the conditions" do
    put_location()
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, forecast_body()) end)

    assert {:ok, conditions} = Weather.current(opts())
    assert conditions.location == "Portland, Oregon"
    assert conditions.temp_f == 72
    assert conditions.feels_like_f == 70
    assert conditions.label == "Partly cloudy"
    assert conditions.high_f == 78
    assert conditions.low_f == 56
    assert conditions.wind_mph == 7
    assert conditions.humidity == 54
  end

  test "current is served from cache within the TTL" do
    put_location()
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :fetched)
      Req.Test.json(conn, forecast_body())
    end)

    assert {:ok, _} = Weather.current(opts())
    assert_received :fetched
    assert {:ok, _} = Weather.current(opts())
    refute_received :fetched
  end

  test "a fetch failure is an error, not a cache entry" do
    put_location()
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

    assert {:error, {:weather_status, 503, _}} = Weather.current(opts())

    # Recovery: the next call fetches again rather than serving a cached error.
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, forecast_body()) end)
    assert {:ok, _} = Weather.current(opts())
  end
end
