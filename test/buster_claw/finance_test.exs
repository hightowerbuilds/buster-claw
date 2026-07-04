defmodule BusterClaw.FinanceTest do
  # async: false — resolve_cik caches the ticker map in :persistent_term.
  use ExUnit.Case, async: false

  alias BusterClaw.Finance.Edgar

  @stub BusterClaw.FinanceHTTP
  @opts [req_options: [plug: {Req.Test, BusterClaw.FinanceHTTP}]]

  setup do
    Req.Test.verify_on_exit!()
    :persistent_term.erase({Edgar, :ticker_map})
    on_exit(fn -> :persistent_term.erase({Edgar, :ticker_map}) end)
    :ok
  end

  defp ticker_map_response do
    %{
      "0" => %{"cik_str" => 320_193, "ticker" => "AAPL", "title" => "Apple Inc."}
    }
  end

  defp multi_ticker_map do
    %{
      "0" => %{"cik_str" => 320_193, "ticker" => "AAPL", "title" => "Apple Inc."},
      "1" => %{"cik_str" => 789_019, "ticker" => "MSFT", "title" => "Microsoft Corp"},
      "2" => %{"cik_str" => 1_18, "ticker" => "APP", "title" => "Applovin Corp"}
    }
  end

  test "search matches by ticker and company name, ranked best-first" do
    Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, multi_ticker_map()) end)

    assert {:ok, results} = Edgar.search("app", @opts)
    symbols = Enum.map(results, & &1.symbol)

    # All three contain "app" (AAPL ticker, APP ticker, Applovin/Apple names);
    # exact/prefix ticker matches rank ahead of name-only matches.
    assert "APP" in symbols and "AAPL" in symbols
    assert hd(symbols) == "APP", "exact ticker match should rank first"
    assert Enum.all?(results, &Map.has_key?(&1, :name))
  end

  test "search by full company name resolves to the ticker" do
    Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, multi_ticker_map()) end)

    assert {:ok, "MSFT"} = Edgar.resolve("microsoft", @opts)
    assert {:ok, "AAPL"} = Edgar.resolve("AAPL", @opts)
    assert {:error, :no_match} = Edgar.resolve("nonexistent-co", @opts)
  end

  test "filings resolves the CIK and returns provenance-stamped recent filings" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/files/company_tickers.json" ->
          Req.Test.json(conn, ticker_map_response())

        "/submissions/CIK0000320193.json" ->
          Req.Test.json(conn, %{
            "filings" => %{
              "recent" => %{
                "form" => ["10-K", "8-K"],
                "filingDate" => ["2025-11-01", "2025-10-15"],
                "reportDate" => ["2025-09-28", ""],
                "accessionNumber" => ["0000320193-25-000123", "0000320193-25-000110"],
                "primaryDocument" => ["aapl-20250928.htm", "ea0001.htm"]
              }
            }
          })
      end
    end)

    assert {:ok, result} = Edgar.filings("aapl", @opts)
    assert result.symbol == "AAPL"
    assert result.cik == "0000320193"
    assert result.company == "Apple Inc."
    assert result.source == "SEC EDGAR"
    assert is_binary(result.as_of)

    assert [first, second] = result.filings
    assert first.form == "10-K"
    assert first.filing_date == "2025-11-01"
    assert first.report_date == "2025-09-28"

    assert first.url ==
             "https://www.sec.gov/Archives/edgar/data/320193/000032019325000123/aapl-20250928.htm"

    # A blank reportDate becomes nil rather than "".
    assert second.report_date == nil
  end

  test "filings honors :limit and only materializes the requested rows" do
    # 50 parallel-array filings; limit far below the total. Regression guard for
    # the O(n²) zip that used to build every row before taking the limit.
    n = 50

    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/files/company_tickers.json" ->
          Req.Test.json(conn, ticker_map_response())

        "/submissions/CIK0000320193.json" ->
          Req.Test.json(conn, %{
            "filings" => %{
              "recent" => %{
                "form" => List.duplicate("8-K", n),
                "filingDate" =>
                  for(i <- 1..n, do: "2025-01-#{String.pad_leading("#{i}", 2, "0")}"),
                "reportDate" => List.duplicate("", n),
                "accessionNumber" =>
                  for(i <- 1..n, do: "0000320193-25-#{String.pad_leading("#{i}", 6, "0")}"),
                "primaryDocument" => for(i <- 1..n, do: "doc#{i}.htm")
              }
            }
          })
      end
    end)

    assert {:ok, result} = Edgar.filings("aapl", Keyword.put(@opts, :limit, 3))
    assert length(result.filings) == 3
    assert Enum.at(result.filings, 0).filing_date == "2025-01-01"
    assert Enum.at(result.filings, 2).filing_date == "2025-01-03"
  end

  test "fundamentals picks the most recent value per concept with its as-of and source" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/files/company_tickers.json" ->
          Req.Test.json(conn, ticker_map_response())

        "/api/xbrl/companyfacts/CIK0000320193.json" ->
          Req.Test.json(conn, %{
            "facts" => %{
              "us-gaap" => %{
                "NetIncomeLoss" => %{
                  "units" => %{
                    "USD" => [
                      %{"val" => 90_000, "end" => "2023-09-30", "form" => "10-K", "fy" => 2023},
                      %{"val" => 100_000, "end" => "2024-09-28", "form" => "10-K", "fy" => 2024}
                    ]
                  }
                }
              }
            }
          })
      end
    end)

    assert {:ok, result} = Edgar.fundamentals("AAPL", @opts)
    assert result.source == "SEC EDGAR (XBRL companyfacts)"

    # Latest by `end` date wins, with provenance attached.
    assert result.facts.net_income == %{
             value: 100_000,
             unit: "USD",
             as_of: "2024-09-28",
             form: "10-K",
             fiscal_year: 2024
           }

    # Concepts absent from the payload are reported as nil, never fabricated.
    assert result.facts.revenue == nil
    assert result.facts.assets == nil
  end

  test "an unknown symbol returns a clear error, not a guess" do
    Req.Test.stub(@stub, fn conn ->
      Req.Test.json(conn, ticker_map_response())
    end)

    assert {:error, {:unknown_symbol, "NOTREAL"}} = Edgar.filings("notreal", @opts)
  end
end
