defmodule BusterClaw.ResearchTest do
  use ExUnit.Case, async: false

  alias BusterClaw.DataState
  alias BusterClaw.Research

  @stub BusterClaw.ResearchHTTP
  @opts [req_options: [plug: {Req.Test, @stub}]]

  setup do
    prev = Application.get_env(:buster_claw, :finnhub_api_key)
    Application.put_env(:buster_claw, :finnhub_api_key, "test-key")
    on_exit(fn -> Application.put_env(:buster_claw, :finnhub_api_key, prev) end)
    :ok
  end

  # One stub for all three upstreams — Research fans out to Finnhub and two
  # EDGAR endpoints, and the point of most of these tests is what happens when
  # they DISAGREE about whether they can answer.
  defp stub(fun), do: Req.Test.stub(@stub, fun)

  defp quote_body,
    do: %{
      "c" => 150.25,
      "d" => 1.5,
      "dp" => 1.01,
      "h" => 151.0,
      "l" => 148.0,
      "o" => 149.0,
      "pc" => 148.75,
      "t" => 1_785_268_800
    }

  defp tickers_body,
    do: %{"0" => %{"cik_str" => 320_193, "ticker" => "AAPL", "title" => "Apple Inc."}}

  describe "the broker boundary" do
    test "a research chat carries no Robinhood tools and no MCP config at all" do
      args = Enum.join(Keyword.fetch!(Research.chat_opts(), :extra_cli_args), " ")

      # Not "denied" — absent. There is no broker surface in this run to confine,
      # which is a stronger property than an allowlist that happens to omit it.
      refute args =~ "robinhood"
      refute args =~ "--mcp-config"
      refute args =~ "--allowedTools"

      # The shell and filesystem stay shut, same as the trading side.
      assert args =~ "--disallowedTools"
      assert args =~ "Bash"
      assert args =~ "Write"
    end

    test "the prompt tells the model the account data is not merely forbidden but absent" do
      prompt = Research.system_prompt()

      assert prompt =~ "NO access to the operator's brokerage accounts"
      assert prompt =~ "there is no tool"
      assert prompt =~ "Robinhood tab is where account data lives"
      assert prompt =~ "cannot place, amend, or cancel"
      # The delay is a correctness claim, not a footnote.
      assert prompt =~ "delayed roughly 15 minutes"
      assert prompt =~ "Never describe one as live"
    end
  end

  describe "load/2" do
    test "a symbol every upstream knows comes back fresh, with sources" do
      stub(fn conn ->
        case conn.request_path do
          "/api/v1/quote" -> Req.Test.json(conn, quote_body())
          "/files/company_tickers.json" -> Req.Test.json(conn, tickers_body())
          _edgar -> Req.Test.json(conn, %{"filings" => %{"recent" => %{}}, "facts" => %{}})
        end
      end)

      result = Research.load("aapl", @opts)

      # Normalized app-side: the panel and both upstreams want it upper case.
      assert result.symbol == "AAPL"
      assert %DataState{status: :fresh, source: :finnhub} = result.quote
      assert result.quote.data.price == 150.25
      assert result.quote.data.source == "Finnhub"
      assert %DateTime{} = result.quote.as_of
    end

    test "a missing Finnhub key leaves the EDGAR panels intact" do
      Application.put_env(:buster_claw, :finnhub_api_key, nil)

      stub(fn conn ->
        case conn.request_path do
          "/files/company_tickers.json" -> Req.Test.json(conn, tickers_body())
          _edgar -> Req.Test.json(conn, %{"filings" => %{"recent" => %{}}, "facts" => %{}})
        end
      end)

      result = Research.load("AAPL", @opts)

      # The whole reason each dataset carries its own state: one key-gated
      # upstream being unconfigured must not blank the two keyless ones.
      assert result.quote.status == :unavailable
      assert result.quote.reason == :not_configured
      assert result.fundamentals.status == :fresh
      assert result.filings.status == :fresh
    end

    test "a symbol EDGAR does not know is unavailable, not empty" do
      stub(fn conn ->
        case conn.request_path do
          "/api/v1/quote" -> Req.Test.json(conn, quote_body())
          _edgar -> Req.Test.json(conn, tickers_body())
        end
      end)

      result = Research.load("NOTAREALTICKER", @opts)

      # "We looked and there is nothing" would be a lie; EDGAR could not resolve
      # the symbol at all.
      assert result.fundamentals.status == :unavailable
      assert {:unknown_symbol, _sym} = result.fundamentals.reason
      assert result.filings.status == :unavailable
    end

    test "an upstream error is unavailable and keeps its reason" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

      result = Research.load("AAPL", @opts)

      assert result.quote.status == :unavailable
      assert result.fundamentals.status == :unavailable
      refute is_nil(result.quote.reason)
    end
  end

  describe "blank/0 and search/2" do
    test "a tab with no symbol says so rather than showing zeros" do
      blank = Research.blank()

      assert is_nil(blank.symbol)

      for k <- [:quote, :fundamentals, :filings] do
        state = Map.fetch!(blank, k)
        assert state.status == :unavailable
        assert state.reason == :no_symbol
        # Never `0` or `[]` — a blank panel must not read as a confirmed answer.
        refute state.data == 0
      end
    end

    test "search returns matches, and a miss is an empty list rather than an error" do
      stub(fn conn -> Req.Test.json(conn, tickers_body()) end)

      assert [%{symbol: "AAPL"} | _rest] = Research.search("apple", @opts)
      assert Research.search("nothing-matches-this", @opts) == []
    end

    test "an upstream failure degrades search to an empty list" do
      # EDGAR memoizes the ticker file in :persistent_term, so the failure has to
      # be arranged against a cold cache or it never reaches the network at all.
      :persistent_term.erase({BusterClaw.Finance.Edgar, :ticker_map})
      stub(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      assert Research.search("apple", @opts) == []
    end
  end
end
