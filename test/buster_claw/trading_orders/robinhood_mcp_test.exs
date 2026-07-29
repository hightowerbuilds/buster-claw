defmodule BusterClaw.TradingOrders.Broker.RobinhoodMCPTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.TradingBroker
  alias BusterClaw.TradingOrders.Broker.RobinhoodMCP

  @stub BusterClaw.TradingBrokerHTTP
  @timestamp "2026-07-28T15:00:00Z"

  setup do
    Req.Test.verify_on_exit!()

    assert {:ok, connection} = TradingBroker.put_client_id("review-client")

    assert {:ok, _connection} =
             TradingBroker.put_tokens(%{
               "access_token" => "review-access",
               "refresh_token" => "review-refresh",
               "expires_in" => 3600
             })

    assert {:ok, [account]} =
             TradingBroker.replace_accounts(connection, [
               %{
                 "account_number" => "RH-REVIEW-ACCOUNT",
                 "nickname" => "Agentic",
                 "agentic_allowed" => true,
                 "state" => "active",
                 "deactivated" => false,
                 "permanently_deactivated" => false
               }
             ])

    Req.Test.stub(@stub, &broker_stub/1)

    {:ok, account: account}
  end

  test "maps exact Robinhood review, portfolio, and position data into local policy facts", %{
    account: account
  } do
    assert {:ok, review} =
             RobinhoodMCP.review(%{
               "account_id" => account.account_key,
               "symbol" => "AAPL",
               "side" => "buy",
               "quantity_micros" => 1_000_000,
               "notional_cents" => nil,
               "order_type" => "limit",
               "limit_price_cents" => 20_100,
               "time_in_force" => "day",
               "client_order_id" => "client-order-id"
             })

    assert review.quote_cents == 20_010
    assert review.buying_power_cents == 500_000
    assert review.estimated_notional_cents == 20_100
    assert review.concentration_bps == 602
    assert review.market_open
    assert review.broker_timestamp == ~U[2026-07-28 15:00:00Z]
    assert String.starts_with?(review.broker_preview_id, "rh-review-")

    assert review.broker_preview["market_data_disclosure"] ==
             "Bid $200.00 · Ask $200.10 · Updated 11:00 AM ET."

    assert review.broker_preview["warnings"] == []
  end

  test "preserves open-ended broker alerts without trying to enumerate them", %{account: account} do
    Process.put(:broker_order_checks, %{
      "alert_type" => "NEW_BROKER_ALERT",
      "new_broker_alert_details" => %{"message" => "Review this condition"}
    })

    on_exit(fn -> Process.delete(:broker_order_checks) end)

    assert {:ok, review} =
             RobinhoodMCP.review(%{
               "account_id" => account.account_key,
               "symbol" => "AAPL",
               "side" => "sell",
               "quantity_micros" => 1_000_000,
               "notional_cents" => nil,
               "order_type" => "market",
               "limit_price_cents" => nil,
               "time_in_force" => "gtc",
               "client_order_id" => "client-order-id"
             })

    assert [warning] = review.broker_preview["warnings"]
    assert warning =~ "NEW_BROKER_ALERT"
    assert warning =~ "Review this condition"
    assert review.concentration_bps == 0
  end

  test "submission remains sealed in the adapter" do
    assert {:error, {:definitive, :broker_submission_sealed}} =
             RobinhoodMCP.submit(%{}, "client-order-id")

    assert {:error, :broker_submission_sealed} = RobinhoodMCP.fetch_order(%{})
  end

  defp broker_stub(conn) do
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer review-access"]

    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)

    case request["method"] do
      "initialize" ->
        conn
        |> Plug.Conn.put_resp_header("mcp-session-id", "review-session")
        |> rpc_result(request, %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "robinhood", "version" => "1"}
        })

      "notifications/initialized" ->
        Plug.Conn.send_resp(conn, 202, "")

      "tools/call" ->
        tool_result(conn, request)
    end
  end

  defp tool_result(conn, %{"params" => %{"name" => "review_equity_order"} = params} = request) do
    arguments = params["arguments"]
    assert arguments["account_number"] == "RH-REVIEW-ACCOUNT"
    assert arguments["symbol"] == "AAPL"
    assert arguments["market_hours"] == "regular_hours"
    assert arguments["time_in_force"] in ["gfd", "gtc"]

    data = %{
      "symbol" => "AAPL",
      "side" => arguments["side"],
      "type" => arguments["type"],
      "quantity" => arguments["quantity"],
      "limit_price" => arguments["limit_price"],
      "order_checks" => Process.get(:broker_order_checks, %{}),
      "market_data_disclosure" => "Bid $200.00 · Ask $200.10 · Updated 11:00 AM ET.",
      "quote_data" => %{
        "symbol" => "AAPL",
        "ask_price" => "200.10",
        "venue_ask_time" => @timestamp,
        "bid_price" => "200.00",
        "venue_bid_time" => @timestamp,
        "last_trade_price" => "200.05",
        "venue_last_trade_time" => @timestamp
      }
    }

    rpc_result(conn, request, %{
      "structuredContent" => %{"data" => data, "guide" => "Review only."}
    })
  end

  defp tool_result(conn, %{"params" => %{"name" => "get_portfolio"} = params} = request) do
    assert params["arguments"] == %{"account_number" => "RH-REVIEW-ACCOUNT"}

    rpc_result(conn, request, %{
      "structuredContent" => %{
        "data" => %{
          "total_value" => "10000.00",
          "buying_power" => %{
            "buying_power" => "5000.00",
            "display_currency" => "USD",
            "unleveraged_buying_power" => "5000.00"
          }
        },
        "guide" => "Portfolio."
      }
    })
  end

  defp tool_result(
         conn,
         %{"params" => %{"name" => "get_equity_positions"} = params} = request
       ) do
    assert params["arguments"] == %{"account_number" => "RH-REVIEW-ACCOUNT"}

    rpc_result(conn, request, %{
      "structuredContent" => %{
        "data" => %{
          "positions" => [%{"symbol" => "AAPL", "quantity" => "2.000000"}],
          "next" => ""
        },
        "guide" => "Positions."
      }
    })
  end

  defp rpc_result(conn, request, result) do
    Req.Test.json(conn, %{
      "jsonrpc" => "2.0",
      "id" => request["id"],
      "result" => result
    })
  end
end
