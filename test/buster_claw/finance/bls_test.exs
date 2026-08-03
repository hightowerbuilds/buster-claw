defmodule BusterClaw.Finance.BLSTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Finance.BLS

  @stub BusterClaw.BLSHTTP
  @opts [req_options: [plug: {Req.Test, @stub}]]

  setup do
    prev = Application.get_env(:buster_claw, :bls_api_key)
    Application.delete_env(:buster_claw, :bls_api_key)
    on_exit(fn -> Application.put_env(:buster_claw, :bls_api_key, prev) end)
    :ok
  end

  defp stub(fun), do: Req.Test.stub(@stub, fun)

  defp row(year, period, name, value),
    do: %{"year" => year, "period" => period, "periodName" => name, "value" => value}

  defp ok_body(rows, series_id \\ "CUUR0000SA0") do
    %{
      "status" => "REQUEST_SUCCEEDED",
      "responseTime" => 138,
      "message" => [],
      "Results" => %{"series" => [%{"seriesID" => series_id, "data" => rows}]}
    }
  end

  defp serve(body), do: stub(fn conn -> Req.Test.json(conn, body) end)

  describe "the M13 trap" do
    test "an annual average is dropped, counted, and explained in the payload" do
      # BLS returns the yearly average as a thirteenth row inside the same
      # data[]. Plotted naively it becomes an extra point at a value no month
      # actually had — the exact shape of a chart that renders crisply and lies.
      serve(
        ok_body([
          row("2025", "M13", "Annual", "321.943"),
          row("2025", "M02", "February", "319.082"),
          row("2025", "M01", "January", "317.671")
        ])
      )

      assert {:ok, result} = BLS.observations("CUUR0000SA0", @opts)

      assert Enum.map(result.observations, & &1.period) == ["M01", "M02"]
      assert result.aggregates_dropped == 1
      assert result.note =~ "annual-average"
      # The value that would have been the phantom point is nowhere in the data.
      refute Enum.any?(result.observations, &(&1.value == 321.943))
    end

    test "Q05 is dropped too — the quarterly series has the same shape" do
      serve(
        ok_body([
          row("2025", "Q05", "Annual", "10.0"),
          row("2025", "Q01", "1st Quarter", "9.0")
        ])
      )

      assert {:ok, result} = BLS.observations("WPUFD4", @opts)
      assert [%{period: "Q01"}] = result.observations
      assert result.aggregates_dropped == 1
    end

    test "include_aggregates keeps them, flagged rather than silently mixed in" do
      serve(
        ok_body([
          row("2025", "M13", "Annual", "321.943"),
          row("2025", "M01", "January", "317.671")
        ])
      )

      assert {:ok, result} =
               BLS.observations("CUUR0000SA0", @opts ++ [include_aggregates: true])

      assert length(result.observations) == 2
      assert Enum.any?(result.observations, &(&1.aggregate and &1.period == "M13"))
      assert Enum.any?(result.observations, &(not &1.aggregate and &1.period == "M01"))
      assert result.aggregates_dropped == 0
    end
  end

  describe "a failure that arrives as HTTP 200" do
    test "REQUEST_NOT_PROCESSED is an error, not an empty success" do
      # The guard this whole adapter needed: BLS signals failure in the BODY.
      # Finnhub's `status in 200..299 -> {:ok, body}` would return success here,
      # and the caller would render an empty chart instead of saying it failed.
      serve(%{
        "status" => "REQUEST_NOT_PROCESSED",
        "responseTime" => 0,
        "message" => ["No Data Available for Series CUUR0000SA0"],
        "Results" => %{}
      })

      assert {:error, {:bls_error, "REQUEST_NOT_PROCESSED", messages}} =
               BLS.observations("CUUR0000SA0", @opts)

      assert messages == ["No Data Available for Series CUUR0000SA0"]
    end

    test "a blown daily quota is reported, not mistaken for no data" do
      serve(%{
        "status" => "REQUEST_NOT_PROCESSED",
        "message" => ["daily threshold for total number of requests exceeded"],
        "Results" => %{}
      })

      assert {:error, {:bls_error, _status, [message]}} = BLS.observations("LNS14000000", @opts)
      assert message =~ "threshold"
    end

    test "a non-2xx status is still an error" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 503, "upstream down") end)
      assert {:error, {:http_error, 503, _body}} = BLS.observations("CUUR0000SA0", @opts)
    end
  end

  describe "values and dates" do
    test "observations are oldest-first, dated to the first of the named period" do
      serve(
        ok_body([
          row("2025", "M03", "March", "319.799"),
          row("2025", "M01", "January", "317.671"),
          row("2025", "M02", "February", "319.082")
        ])
      )

      assert {:ok, result} = BLS.observations("CUUR0000SA0", @opts)

      assert Enum.map(result.observations, & &1.date) ==
               [~D[2025-01-01], ~D[2025-02-01], ~D[2025-03-01]]

      # BLS names a month, not a day. Filing on the 1st is the only date the
      # source implies; a 15th or a month-end would be invented precision.
      assert Enum.map(result.observations, & &1.value) == [317.671, 319.082, 319.799]
    end

    test "a quarter is dated to the first month of the quarter" do
      serve(ok_body([row("2025", "Q03", "3rd Quarter", "5.5")]))
      assert {:ok, %{observations: [%{date: ~D[2025-07-01]}]}} = BLS.observations("WPUFD4", @opts)
    end

    test "an unpublished value is dropped, never defaulted to zero" do
      # A zero in a price index draws a cliff. Same rule MarketData enforces on
      # a zero close: prefer a gap to a guess.
      serve(
        ok_body([
          row("2025", "M01", "January", "317.671"),
          row("2025", "M02", "February", "-"),
          row("2025", "M03", "March", "")
        ])
      )

      assert {:ok, %{observations: [only]}} = BLS.observations("CUUR0000SA0", @opts)
      assert only.value == 317.671
    end

    test "a value with trailing garbage is refused rather than truncated" do
      # Float.parse("12abc") returns {12.0, "abc"} — accepting that would put a
      # fabricated figure on a chart.
      serve(ok_body([row("2025", "M01", "January", "12abc")]))
      assert {:ok, %{observations: []}} = BLS.observations("CUUR0000SA0", @opts)
    end
  end

  describe "the series id is validated, not trusted" do
    test "a path-traversing id is refused before any request is made" do
      # Defence in depth, kept deliberately. The id now travels in the POST body
      # rather than the URL path, so a slash can no longer select an endpoint —
      # but the id is model-supplied, the validation costs one regex, and the
      # thing that made it load-bearing (a GET route) was removed only after this
      # test was written. Keep it, so re-introducing a path route is not a
      # silent re-introduction of the hole.
      # No stub is installed: reaching HTTP at all fails this test.
      assert {:error, {:invalid_series_id, _}} = BLS.observations("../../v2/timeseries", @opts)
      assert {:error, {:invalid_series_id, _}} = BLS.observations("CUUR0000SA0/../foo", @opts)
      assert {:error, {:invalid_series_id, _}} = BLS.observations("", @opts)
    end

    test "a real id is normalized to upper case" do
      serve(ok_body([row("2025", "M01", "January", "317.671")]))
      assert {:ok, %{series_id: "CUUR0000SA0"}} = BLS.observations("cuur0000sa0", @opts)
    end
  end

  describe "provenance and quota" do
    test "every result names its source and carries an as_of" do
      serve(ok_body([row("2025", "M01", "January", "317.671")]))

      assert {:ok, result} = BLS.observations("CUUR0000SA0", @opts)
      assert result.source == "U.S. Bureau of Labor Statistics"
      assert result.source_url =~ "bls.gov"
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(result.as_of)

      # A known series carries its units, because a CPI index number means
      # nothing without "index 1982-84=100" beside it.
      assert result.title =~ "CPI-U"
      assert result.units == "index 1982-84=100"
      assert result.frequency == "monthly"
    end

    test "an unknown-but-valid series still returns data, just without a title" do
      serve(ok_body([row("2025", "M01", "January", "1.0")], "SUZ12345678"))
      assert {:ok, result} = BLS.observations("SUZ12345678", @opts)
      assert result.title == nil
      assert [%{value: 1.0}] = result.observations
    end

    test "the documented quota reflects whether a key is configured" do
      assert BLS.daily_quota() == 25
      Application.put_env(:buster_claw, :bls_api_key, "key")
      assert BLS.daily_quota() == 500
    end

    test "a configured key goes in the POST body, never the query string" do
      Application.put_env(:buster_claw, :bls_api_key, "secret-key")

      stub(fn conn ->
        assert conn.method == "POST"
        # A key in a query string lands in logs and referrers. Assert the whole
        # URL is clean rather than trusting the request builder.
        refute conn.query_string =~ "secret-key"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert raw =~ "secret-key"
        assert raw =~ "CUUR0000SA0"
        Req.Test.json(conn, ok_body([row("2025", "M01", "January", "317.671")]))
      end)

      assert {:ok, %{observations: [_one]}} = BLS.observations("CUUR0000SA0", @opts)
    end

    test "with no key it POSTs the keyless v1 route, with the years in the body" do
      # NOT a GET. The v1 GET route accepts startyear/endyear and silently
      # ignores them — measured 08-03, asking for 2024-2025 returned data through
      # 2026-06. A well-formed 200 for a window nobody asked for is the worst
      # failure available on a charting surface, so the GET route is not used.
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/publicAPI/v1/timeseries/data/"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert raw =~ ~s("startyear":"2022")
        assert raw =~ ~s("endyear":"2023")
        assert raw =~ "CUUR0000SA0"
        refute raw =~ "registrationkey"
        Req.Test.json(conn, ok_body([row("2022", "M01", "January", "281.148")]))
      end)

      assert {:ok, %{observations: [_one]}} =
               BLS.observations("CUUR0000SA0", @opts ++ [start_year: 2022, end_year: 2023])
    end

    test "the payload states the span it actually delivered, not the one requested" do
      # The guard that would have caught the v1 GET bug from the outside. A
      # caller labelling a chart from `requested` would have been wrong; only
      # `covered` describes the data in hand.
      serve(
        ok_body([
          row("2024", "M01", "January", "308.417"),
          row("2026", "M06", "June", "333.952")
        ])
      )

      assert {:ok, result} =
               BLS.observations("CUUR0000SA0", @opts ++ [start_year: 2024, end_year: 2025])

      assert result.requested == %{from_year: 2024, to_year: 2025}
      assert result.covered == %{from: ~D[2024-01-01], to: ~D[2026-06-01]}
    end

    test "an empty series reports no covered range rather than a bogus one" do
      serve(ok_body([]))
      assert {:ok, %{observations: [], covered: nil}} = BLS.observations("CUUR0000SA0", @opts)
    end
  end
end
