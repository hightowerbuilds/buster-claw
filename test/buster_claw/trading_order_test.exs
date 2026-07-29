defmodule BusterClaw.TradingOrderTest do
  use ExUnit.Case, async: true

  alias BusterClaw.TradingOrder

  defp block(json), do: "Here's the order I'd place.\n\n```order\n#{json}\n```"

  describe "parse/1 — what arms the card" do
    test "a complete limit proposal parses into the struct the card renders" do
      text =
        block(
          ~s({"side":"buy","symbol":"AAPL","quantity":2,"order_type":"limit",) <>
            ~s("limit_price":199.25,"time_in_force":"day","account_last4":"6587"})
        )

      assert {:ok, order} = TradingOrder.parse(text)
      assert order.side == "buy"
      assert order.symbol == "AAPL"
      assert order.quantity == 2.0
      assert order.limit_price == 199.25
      assert order.time_in_force == "day"
      assert order.account_last4 == "6587"
      assert TradingOrder.summary(order) =~ "BUY · 2 sh · AAPL · LIMIT $199.25 · DAY"
    end

    test "a dollar-sized market order parses, and reads as dollars" do
      text =
        block(
          ~s({"side":"buy","symbol":"VOO","amount_usd":250,"order_type":"market",) <>
            ~s("time_in_force":"gtc","account_last4":"6587"})
        )

      assert {:ok, order} = TradingOrder.parse(text)
      assert order.amount_usd == 250.0
      assert is_nil(order.quantity)
      assert TradingOrder.summary(order) =~ "$250 · VOO · MARKET · GTC"
    end

    test "prose about orders does NOT arm the card — the fence is the trigger" do
      assert TradingOrder.parse("""
             A limit order sets a maximum price. For example you might buy 2 AAPL
             at a limit of 199.25, in a JSON shape like
             {"side": "buy", "symbol": "AAPL", "quantity": 2}.
             """) == :none
    end

    test "an ordinary answer with no block is not an error" do
      assert TradingOrder.parse("Your Roth IRA is worth $900.") == :none
    end

    test "a block missing the size is refused rather than defaulted" do
      text =
        block(
          ~s({"side":"buy","symbol":"AAPL","order_type":"market",) <>
            ~s("time_in_force":"day","account_last4":"6587"})
        )

      assert TradingOrder.parse(text) == {:error, :missing_size}
    end

    test "shares AND dollars together is refused — the size must be unambiguous" do
      text =
        block(
          ~s({"side":"buy","symbol":"AAPL","quantity":2,"amount_usd":250,) <>
            ~s("order_type":"market","time_in_force":"day","account_last4":"6587"})
        )

      assert TradingOrder.parse(text) == {:error, :ambiguous_size}
    end

    test "a limit order with no price is refused rather than filled in" do
      text =
        block(
          ~s({"side":"sell","symbol":"AAPL","quantity":1,"order_type":"limit",) <>
            ~s("time_in_force":"day","account_last4":"6587"})
        )

      assert TradingOrder.parse(text) == {:error, :missing_limit_price}
    end

    test "a market order carrying a price is refused, not silently stripped" do
      text =
        block(
          ~s({"side":"sell","symbol":"AAPL","quantity":1,"order_type":"market",) <>
            ~s("limit_price":100,"time_in_force":"day","account_last4":"6587"})
        )

      assert TradingOrder.parse(text) == {:error, :limit_price_on_market_order}
    end

    test "junk in the enumerated fields is refused" do
      base = fn overrides ->
        %{
          "side" => "buy",
          "symbol" => "AAPL",
          "quantity" => 1,
          "order_type" => "market",
          "time_in_force" => "day",
          "account_last4" => "6587"
        }
        |> Map.merge(overrides)
        |> Jason.encode!()
        |> block()
        |> TradingOrder.parse()
      end

      assert base.(%{"side" => "short"}) == {:error, :invalid_side}
      assert base.(%{"order_type" => "stop"}) == {:error, :invalid_order_type}
      assert base.(%{"time_in_force" => "forever"}) == {:error, :invalid_time_in_force}
      assert base.(%{"symbol" => "not a ticker"}) == {:error, :invalid_symbol}
      assert base.(%{"account_last4" => "65"}) == {:error, :invalid_account}
      assert base.(%{"quantity" => -5}) == {:error, :missing_size}
    end

    test "an unparseable block is reported, not ignored" do
      assert TradingOrder.parse("```order\nnot json at all\n```") ==
               {:error, :unreadable_order_block}
    end
  end

  describe "submit_cli_args/0 — the write tool lives here and nowhere else" do
    test "the submit run allowlists the order tool; the chat run never does" do
      submit = Enum.join(TradingOrder.submit_cli_args(), " ")
      chat = Enum.join(BusterClaw.Trading.read_only_cli_args(), " ")

      assert submit =~ "mcp__robinhood__place_equity_order"
      refute chat =~ "place_equity_order"

      # Built-in tools stay off and the MCP config stays scoped in both.
      assert submit =~ "--strict-mcp-config"
      refute submit =~ "mcp__robinhood__get_equity_quotes"
    end
  end

  describe "submit_prompt/1 — parameters are literals, not prose" do
    test "the prompt carries the parsed values and forbids a retry" do
      {:ok, order} =
        TradingOrder.parse(
          block(
            ~s({"side":"sell","symbol":"VOO","quantity":1.5,"order_type":"limit",) <>
              ~s("limit_price":512.5,"time_in_force":"gtc","account_last4":"4821"})
          )
        )

      prompt = TradingOrder.submit_prompt(order)

      assert prompt =~ "side: sell"
      assert prompt =~ "symbol: VOO"
      assert prompt =~ "quantity in shares: 1.5"
      assert prompt =~ "limit price: 512.5"
      assert prompt =~ "time in force: gtc"
      assert prompt =~ "IN 4821"
      assert prompt =~ "Never retry a place_equity_order call."
    end
  end

  describe "parse_submit_result/1 — a verdict, or an honest unknown" do
    test "an accepted order returns its broker id" do
      assert TradingOrder.parse_submit_result(~s({"order_id":"abc-123","state":"queued"})) ==
               {:ok, "abc-123"}
    end

    test "a clean broker refusal keeps its reason" do
      assert TradingOrder.parse_submit_result(~s({"error":"insufficient buying power"})) ==
               {:error, {:refused, "insufficient buying power"}}
    end

    test "an unresolved tool call is UNKNOWN, never a refusal" do
      # The distinction that matters: a refusal means nothing was placed, an
      # unknown means something might have been.
      assert TradingOrder.parse_submit_result(
               ~s({"error":"unknown — order status not confirmed"})
             ) == {:error, :unknown}
    end

    test "unreadable output is unknown rather than assumed failed" do
      assert TradingOrder.parse_submit_result("the run died") == {:error, :unknown}
      assert TradingOrder.parse_submit_result(~s({"state":"queued"})) == {:error, :unknown}
    end
  end
end
