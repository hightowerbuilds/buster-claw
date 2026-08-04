defmodule BusterClaw.ChartBuilder.DataReqTest do
  use ExUnit.Case, async: false

  alias BusterClaw.ChartBuilder.DataReq

  @stub BusterClaw.DataReqHTTP
  @opts [req_options: [plug: {Req.Test, @stub}]]

  setup do
    prev = Application.get_env(:buster_claw, :bls_api_key)
    Application.delete_env(:buster_claw, :bls_api_key)
    on_exit(fn -> Application.put_env(:buster_claw, :bls_api_key, prev) end)
    :ok
  end

  defp row(year, period, name, value),
    do: %{"year" => year, "period" => period, "periodName" => name, "value" => value}

  defp serve(rows) do
    Req.Test.stub(@stub, fn conn ->
      Req.Test.json(conn, %{
        "status" => "REQUEST_SUCCEEDED",
        "message" => [],
        "Results" => %{"series" => [%{"seriesID" => "CUUR0000SA0", "data" => rows}]}
      })
    end)
  end

  defp fence(json), do: "Here is what I need.\n\n```datareq\n#{json}\n```"

  describe "extract/1" do
    test "splits prose from the request, like the svg channel it mirrors" do
      {clean, [req]} =
        DataReq.extract(fence(~s({"source":"bls","series":"CUUR0000SA0","start_year":2020})))

      assert clean == "Here is what I need."
      assert req.source == "bls"
      assert req.series == "CUUR0000SA0"
      assert req.start_year == 2020
      assert req.end_year == nil
    end

    test "text with no block yields no requests and is left alone" do
      assert {"just talking", []} = DataReq.extract("just talking")
    end

    test "a malformed block still comes back, so the model can be told" do
      # Dropping it silently is how a conversation deadlocks: the model waits
      # for data that will never arrive and eventually invents it.
      {_clean, [invalid]} = DataReq.extract("```datareq\nnot json at all\n```")
      assert invalid == {:invalid, :malformed_json}
    end

    test "an unknown source is refused at parse time, never fetched" do
      {_clean, [invalid]} = DataReq.extract(fence(~s({"source":"nonesuch","series":"X"})))
      assert invalid == {:invalid, {:unknown_source, "nonesuch"}}
    end

    # A source the registry DOCUMENTS but this channel cannot reach is a
    # different answer from a name nobody recognises, and the model needs the
    # difference: one means "you got the spelling wrong", the other means "stop
    # asking, and tell the operator why".
    test "a documented-but-unfetchable source is refused as itself, carrying its status" do
      {_clean, [invalid]} = DataReq.extract(fence(~s({"source":"fred","series":"CPIAUCSL"})))
      assert invalid == {:invalid, {:unfetchable_source, "fred", :blocked}}

      {_clean, [candidate]} = DataReq.extract(fence(~s({"source":"bea","series":"NIPA/T10101"})))
      assert candidate == {:invalid, {:unfetchable_source, "bea", :candidate}}
    end

    test "a request with no series is refused" do
      {_clean, [invalid]} = DataReq.extract(fence(~s({"source":"bls"})))
      assert invalid == {:invalid, :missing_series}
    end

    test "several blocks all come back — the caller decides to run only one" do
      text =
        fence(~s({"source":"bls","series":"CUUR0000SA0"})) <>
          "\n```datareq\n" <> ~s({"source":"bls","series":"LNS14000000"}) <> "\n```"

      {_clean, requests} = DataReq.extract(text)
      assert length(requests) == 2
    end
  end

  describe "fulfill/2" do
    test "returns provenance-carrying observations" do
      serve([row("2025", "M01", "January", "317.671"), row("2025", "M02", "February", "319.082")])

      {_clean, [req]} = DataReq.extract(fence(~s({"source":"bls","series":"CUUR0000SA0"})))
      assert {:ok, payload} = DataReq.fulfill(req, @opts)

      assert payload.source == "U.S. Bureau of Labor Statistics"
      assert payload.series_id == "CUUR0000SA0"
      assert length(payload.observations) == 2
      assert payload.truncated == 0
      assert payload.covered == %{from: ~D[2025-01-01], to: ~D[2025-02-01]}
    end

    test "an oversized series is trimmed from the OLD end, and says how many" do
      # A chart of a long series wants the recent end. Trimming the recent end
      # would be the wrong half, and trimming silently would make a bounded
      # payload look complete.
      rows =
        for y <- 1990..2025, m <- 1..12 do
          row(to_string(y), "M#{String.pad_leading(to_string(m), 2, "0")}", "M", "100.0")
        end

      serve(rows)

      {_clean, [req]} = DataReq.extract(fence(~s({"source":"bls","series":"CUUR0000SA0"})))
      assert {:ok, payload} = DataReq.fulfill(req, @opts)

      assert length(payload.observations) == DataReq.max_observations()
      assert payload.truncated == length(rows) - DataReq.max_observations()
      assert List.last(payload.observations).date == ~D[2025-12-01]
    end

    test "an upstream rejection is an error, not an empty success" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{
          "status" => "REQUEST_NOT_PROCESSED",
          "message" => ["No Data Available for Series XYZ"],
          "Results" => %{}
        })
      end)

      {_clean, [req]} = DataReq.extract(fence(~s({"source":"bls","series":"XYZ"})))
      assert {:error, {:bls_error, _status, _messages}} = DataReq.fulfill(req, @opts)
    end
  end

  describe "deliver/1 — what the model actually receives" do
    test "a success is labelled plottable and carries source, as_of and covered" do
      serve([row("2025", "M01", "January", "317.671")])
      {_clean, [req]} = DataReq.extract(fence(~s({"source":"bls","series":"CUUR0000SA0"})))

      text = req |> DataReq.fulfill(@opts) |> DataReq.deliver()

      assert text =~ "fetched by the application, not by you"
      assert text =~ "They are\nplottable"
      assert text =~ "U.S. Bureau of Labor Statistics"
      assert text =~ "\"covered\""
      assert text =~ "2025-01-01"
      # The rule from the BLS `requested` vs `covered` finding, restated at the
      # point of delivery where it actually binds.
      assert text =~ "never the span that was requested"
    end

    test "a truncated delivery says so in prose, not only in a JSON field" do
      rows =
        for y <- 1990..2025, m <- 1..12 do
          row(to_string(y), "M#{String.pad_leading(to_string(m), 2, "0")}", "M", "100.0")
        end

      serve(rows)
      {_clean, [req]} = DataReq.extract(fence(~s({"source":"bls","series":"CUUR0000SA0"})))
      text = req |> DataReq.fulfill(@opts) |> DataReq.deliver()

      assert text =~ "were trimmed to bound this payload"
      assert text =~ "rather than implying full coverage"
    end

    test "the M13 note travels to the model when rows were dropped" do
      serve([row("2025", "M13", "Annual", "321.9"), row("2025", "M01", "January", "317.671")])
      {_clean, [req]} = DataReq.extract(fence(~s({"source":"bls","series":"CUUR0000SA0"})))
      text = req |> DataReq.fulfill(@opts) |> DataReq.deliver()

      assert text =~ "annual-average"
    end

    test "every failure names a reason AND what to do about it" do
      # A reason with no instruction is how a model ends up retrying a broken
      # request until the budget runs out.
      for result <- [
            {:error, {:bls_error, "REQUEST_NOT_PROCESSED", ["No Data Available"]}},
            {:error, {:http_error, 503, "down"}},
            {:error, {:invalid_series_id, "../x"}},
            {:error, :timeout}
          ] do
        text = DataReq.deliver(result)
        assert text =~ "buster-claw data delivery"
        assert text != ""
        assert String.length(text) > 60
      end

      assert DataReq.deliver({:error, {:http_error, 503, "x"}}) =~ "upstream problem"
      assert DataReq.deliver({:error, :timeout}) =~ "Do not plot anything"
    end
  end

  describe "refusals" do
    test "an unknown source is told what the real ones are" do
      text = DataReq.refuse({:invalid, {:unknown_source, "nonesuch"}})

      assert text =~ ~s("nonesuch" is not a source)
      assert text =~ "bls"
      assert text =~ "CUUR0000SA0"
      # A dead end for the model is a dead end for the operator unless it says so.
      assert text =~ "tell the operator"
    end

    test "an unfetchable source is told WHY, and told not to retry into it" do
      blocked = DataReq.refuse({:invalid, {:unfetchable_source, "fred", :blocked}})
      assert blocked =~ "knows about"
      assert blocked =~ "terms forbid"
      # The whole point of naming the status: retrying cannot change any of these.
      assert blocked =~ "not something you can retry into working"
      assert blocked =~ "tell the operator"

      candidate = DataReq.refuse({:invalid, {:unfetchable_source, "bea", :candidate}})
      assert candidate =~ "never actually called"

      assert DataReq.refuse({:invalid, {:unfetchable_source, "yahoo_unofficial", :unsanctioned}}) =~
               "no licence"
    end

    test "the loop brake tells it to stop rather than rephrase" do
      text = DataReq.refuse_repeat("bls:XYZ::")
      assert text =~ "already asked for this"
      assert text =~ "Stop requesting it"
      assert text =~ "bls:XYZ::"
    end

    test "a spent budget forbids further blocks explicitly" do
      assert DataReq.refuse_budget() =~ "Do not emit another datareq block"
    end

    test "extra blocks in one message are reported, not silently dropped" do
      assert DataReq.refuse_extra(2) =~ "2 additional datareq block(s)"
    end
  end

  describe "the source registry" do
    test "FRED is deliberately absent" do
      # Its terms prohibit use "in connection with ... large language models"
      # and prohibit caching. BLS publishes the same numbers as a federal work.
      # If FRED is ever added, that decision must be made on the terms, not by
      # someone noticing the registry looks short.
      refute Map.has_key?(DataReq.sources(), "fred")
      assert Map.has_key?(DataReq.sources(), "bls")
    end

    test "signatures are stable, so a caller can spot a repeat" do
      {_clean, [a]} = DataReq.extract(fence(~s({"source":"bls","series":"X","start_year":2020})))
      {_clean, [b]} = DataReq.extract(fence(~s({"source":"bls","series":"X","start_year":2020})))
      {_clean, [c]} = DataReq.extract(fence(~s({"source":"bls","series":"Y","start_year":2020})))

      assert DataReq.signature(a) == DataReq.signature(b)
      assert DataReq.signature(a) != DataReq.signature(c)
    end
  end

  describe "the market source — cache only, never a broker fetch" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(BusterClaw.Repo)
      :ok
    end

    defp store(symbol, pairs) do
      BusterClaw.MarketData.store_bars(%{
        symbol =>
          Enum.map(pairs, fn {day, close} ->
            %{bar_on: Date.from_iso8601!(day), close: close}
          end)
      })
    end

    test "a cached benchmark comes back as plottable closes in dollars" do
      store("SPY", [{"2025-01-02", 590.5}, {"2025-01-03", 595.25}])

      {_clean, [req]} = DataReq.extract(fence(~s({"source":"market","series":"SPY"})))
      assert {:ok, payload} = DataReq.fulfill(req)

      assert payload.series_id == "SPY"
      assert payload.units == "USD"
      # Cents in the table, dollars at the boundary, converted once.
      assert Enum.map(payload.observations, & &1.value) == [590.5, 595.25]
      assert payload.covered == %{from: ~D[2025-01-02], to: ~D[2025-01-03]}
    end

    test "an uncached symbol is NOT a broker fetch — it is a clean refusal" do
      # The load-bearing property. Chart Build is cached-only by construction; a
      # datareq that could trigger a broker run would end that quietly, and this
      # tab's whole cost model rests on it.
      store("SPY", [{"2025-01-02", 590.5}])

      {_clean, [req]} = DataReq.extract(fence(~s({"source":"market","series":"NVDA"})))
      assert {:error, {:not_cached, "NVDA", available}} = DataReq.fulfill(req)
      assert "SPY" in available
    end

    test "the refusal names what IS drawable and forbids substituting" do
      store("SPY", [{"2025-01-02", 590.5}])
      {_clean, [req]} = DataReq.extract(fence(~s({"source":"market","series":"NVDA"})))

      text = req |> DataReq.fulfill() |> DataReq.deliver()

      assert text =~ "not in this app's market cache"
      assert text =~ "does not trigger a broker fetch"
      assert text =~ "SPY"
      # Charting a near-enough ticker instead would be exactly the class of
      # quiet wrongness this whole surface refuses.
      assert text =~ "Do not substitute a different"
    end

    test "a year filter narrows to the requested years" do
      store("SPY", [{"2024-06-03", 500.0}, {"2025-01-02", 590.5}])

      {_clean, [req]} =
        DataReq.extract(fence(~s({"source":"market","series":"SPY","start_year":2025})))

      assert {:ok, payload} = DataReq.fulfill(req)
      assert Enum.map(payload.observations, & &1.date) == [~D[2025-01-02]]
    end

    test "the delivery says these are closes, not an official index level" do
      store("SPY", [{"2025-01-02", 590.5}])
      {_clean, [req]} = DataReq.extract(fence(~s({"source":"market","series":"SPY"})))

      text = req |> DataReq.fulfill() |> DataReq.deliver()
      assert text =~ "Not an official index level"
      assert text =~ "not adjusted for dividends"
    end

    test "a lowercase ticker still resolves" do
      store("SPY", [{"2025-01-02", 590.5}])
      {_clean, [req]} = DataReq.extract(fence(~s({"source":"market","series":"spy"})))
      assert {:ok, %{series_id: "SPY"}} = DataReq.fulfill(req)
    end
  end
end
