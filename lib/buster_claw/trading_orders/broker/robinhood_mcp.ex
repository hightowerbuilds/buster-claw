defmodule BusterClaw.TradingOrders.Broker.RobinhoodMCP do
  @moduledoc """
  Review-only Robinhood Trading MCP adapter.

  This module converts the exact, structured `review_equity_order`,
  `get_portfolio`, and `get_equity_positions` results into BusterClaw's local
  policy contract. Submission and reconciliation deliberately remain sealed.
  """

  @behaviour BusterClaw.TradingOrders.Broker

  alias BusterClaw.MarketCalendar
  alias BusterClaw.TradingBroker
  alias BusterClaw.TradingBroker.Account
  alias BusterClaw.TradingBroker.MCPClient

  @max_position_pages 10

  @impl true
  def review(request) when is_map(request) do
    with {:ok, account} <- eligible_account(request),
         {:ok, arguments} <- review_arguments(request, account),
         {:ok, broker_review} <- MCPClient.call_tool("review_equity_order", arguments),
         {:ok, review_data} <- data(broker_review),
         {:ok, quote_cents, broker_timestamp} <-
           extract_quote(review_data, request["side"]),
         {:ok, estimated_notional_cents} <-
           estimated_notional(request, quote_cents),
         {:ok, portfolio} <-
           MCPClient.call_tool("get_portfolio", %{
             "account_number" => account.broker_account_id
           }),
         {:ok, portfolio_data} <- data(portfolio),
         {:ok, buying_power_cents} <- buying_power(portfolio_data),
         {:ok, concentration_bps} <-
           concentration(
             request,
             account,
             portfolio_data,
             quote_cents,
             estimated_notional_cents
           ) do
      preview = broker_preview(broker_review, review_data)

      {:ok,
       %{
         quote_cents: quote_cents,
         buying_power_cents: buying_power_cents,
         estimated_notional_cents: estimated_notional_cents,
         concentration_bps: concentration_bps,
         market_open: regular_market_open?(broker_timestamp),
         broker_preview: preview,
         broker_preview_id: preview_fingerprint(arguments, preview),
         broker_timestamp: broker_timestamp
       }}
    end
  end

  def review(_request), do: {:error, :invalid_broker_review_request}

  @impl true
  def submit(_intent, _client_order_id),
    do: {:error, {:definitive, :broker_submission_sealed}}

  @impl true
  def fetch_order(_intent), do: {:error, :broker_submission_sealed}

  defp eligible_account(%{"account_id" => account_key}) when is_binary(account_key) do
    case TradingBroker.get_account_by_key(account_key) do
      %Account{agentic: true, can_trade: true, broker_account_id: broker_id} = account
      when is_binary(broker_id) and broker_id != "" ->
        {:ok, account}

      %Account{} ->
        {:error, :broker_account_not_eligible}

      nil ->
        {:error, :broker_account_not_found}
    end
  end

  defp eligible_account(_request), do: {:error, :broker_account_not_found}

  defp review_arguments(request, account) do
    base = %{
      "account_number" => account.broker_account_id,
      "market_hours" => "regular_hours",
      "side" => request["side"],
      "symbol" => request["symbol"],
      "time_in_force" => time_in_force(request["time_in_force"]),
      "type" => request["order_type"]
    }

    with {:ok, amount} <- amount_argument(request),
         {:ok, price} <- price_argument(request) do
      {:ok, base |> Map.merge(amount) |> Map.merge(price)}
    end
  end

  defp amount_argument(%{"quantity_micros" => micros, "notional_cents" => nil})
       when is_integer(micros) and micros > 0,
       do: {:ok, %{"quantity" => format_scaled_integer(micros, 6)}}

  defp amount_argument(%{
         "quantity_micros" => nil,
         "notional_cents" => cents,
         "order_type" => "market"
       })
       when is_integer(cents) and cents > 0,
       do: {:ok, %{"dollar_amount" => format_scaled_integer(cents, 2)}}

  defp amount_argument(%{"notional_cents" => cents}) when is_integer(cents),
    do: {:error, :broker_notional_requires_market_order}

  defp amount_argument(_request), do: {:error, :invalid_broker_order_amount}

  defp price_argument(%{"order_type" => "market", "limit_price_cents" => nil}),
    do: {:ok, %{}}

  defp price_argument(%{"order_type" => "limit", "limit_price_cents" => cents})
       when is_integer(cents) and cents > 0,
       do: {:ok, %{"limit_price" => format_scaled_integer(cents, 2)}}

  defp price_argument(_request), do: {:error, :invalid_broker_order_price}

  defp time_in_force("day"), do: "gfd"
  defp time_in_force("gtc"), do: "gtc"
  defp time_in_force(_value), do: nil

  defp data(%{"data" => data}) when is_map(data), do: {:ok, data}
  defp data(_result), do: {:error, :invalid_broker_tool_result}

  defp extract_quote(%{"quote_data" => quote}, side) when is_map(quote) do
    candidates =
      case side do
        "buy" ->
          [
            {quote["ask_price"], quote["venue_ask_time"]},
            {quote["last_trade_price"], quote["venue_last_trade_time"]}
          ]

        "sell" ->
          [
            {quote["bid_price"], quote["venue_bid_time"]},
            {quote["last_trade_price"], quote["venue_last_trade_time"]}
          ]

        _other ->
          []
      end

    Enum.find_value(candidates, {:error, :broker_quote_unavailable}, fn {price, timestamp} ->
      with {:ok, cents} <- money_to_cents(price),
           true <- cents > 0,
           {:ok, datetime} <- parse_datetime(timestamp) do
        {:ok, cents, datetime}
      else
        _other -> nil
      end
    end)
  end

  defp extract_quote(_data, _side), do: {:error, :broker_quote_unavailable}

  defp estimated_notional(%{"notional_cents" => cents}, _quote_cents)
       when is_integer(cents) and cents > 0,
       do: {:ok, cents}

  defp estimated_notional(
         %{
           "quantity_micros" => micros,
           "order_type" => "limit",
           "limit_price_cents" => limit_cents
         },
         _quote_cents
       )
       when is_integer(micros) and micros > 0 and is_integer(limit_cents) and limit_cents > 0,
       do: {:ok, multiply_quantity(micros, limit_cents)}

  defp estimated_notional(%{"quantity_micros" => micros}, quote_cents)
       when is_integer(micros) and micros > 0,
       do: {:ok, multiply_quantity(micros, quote_cents)}

  defp estimated_notional(_request, _quote_cents),
    do: {:error, :invalid_estimated_notional}

  defp buying_power(%{"buying_power" => %{"buying_power" => value}}),
    do: money_to_non_negative_cents(value)

  defp buying_power(_portfolio), do: {:error, :missing_buying_power}

  defp concentration(%{"side" => "sell"}, _account, _portfolio, _quote, _notional),
    do: {:ok, 0}

  defp concentration(
         %{"side" => "buy", "symbol" => symbol},
         account,
         portfolio,
         quote_cents,
         notional_cents
       ) do
    with {:ok, total_value_cents} <- money_to_cents(portfolio["total_value"]),
         true <- total_value_cents > 0,
         {:ok, quantity_micros} <- position_quantity(account, symbol) do
      position_cents = multiply_quantity(max(quantity_micros, 0), quote_cents)
      numerator = position_cents + notional_cents
      {:ok, min(div(numerator * 10_000 + total_value_cents - 1, total_value_cents), 10_000)}
    else
      false -> {:error, :missing_portfolio_value}
      {:error, _reason} = error -> error
    end
  end

  defp concentration(_request, _account, _portfolio, _quote, _notional),
    do: {:error, :missing_concentration}

  defp position_quantity(account, symbol),
    do: position_quantity(account, symbol, nil, 0)

  defp position_quantity(_account, _symbol, _cursor, page)
       when page >= @max_position_pages,
       do: {:error, :broker_position_pagination_limit}

  defp position_quantity(account, symbol, cursor, page) do
    arguments =
      %{"account_number" => account.broker_account_id}
      |> maybe_put_cursor(cursor)

    with {:ok, result} <- MCPClient.call_tool("get_equity_positions", arguments),
         {:ok, page_data} <- data(result),
         positions when is_list(positions) <- Map.get(page_data, "positions", []),
         {:ok, quantity} <- quantity_for_symbol(positions, symbol) do
      if quantity != 0 or blank?(page_data["next"]) do
        {:ok, quantity}
      else
        case next_cursor(page_data["next"]) do
          {:ok, next} -> position_quantity(account, symbol, next, page + 1)
          :none -> {:ok, 0}
          {:error, _reason} = error -> error
        end
      end
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_broker_positions}
    end
  end

  defp quantity_for_symbol(positions, symbol) do
    case Enum.find(positions, &(Map.get(&1, "symbol") == symbol)) do
      nil -> {:ok, 0}
      %{"quantity" => quantity} -> quantity_to_micros(quantity)
      _other -> {:error, :invalid_broker_position}
    end
  end

  defp next_cursor(url) when is_binary(url) and url != "" do
    case url |> URI.parse() |> Map.get(:query) do
      query when is_binary(query) ->
        case URI.decode_query(query)["cursor"] do
          cursor when is_binary(cursor) and cursor != "" -> {:ok, cursor}
          _other -> {:error, :invalid_broker_position_cursor}
        end

      _other ->
        {:error, :invalid_broker_position_cursor}
    end
  end

  defp next_cursor(_url), do: :none

  defp maybe_put_cursor(arguments, cursor) when is_binary(cursor),
    do: Map.put(arguments, "cursor", cursor)

  defp maybe_put_cursor(arguments, _cursor), do: arguments

  defp broker_preview(broker_review, review_data) do
    checks = Map.get(review_data, "order_checks", %{})

    %{
      "market_data_disclosure" => Map.get(review_data, "market_data_disclosure"),
      "order_checks" => checks,
      "quote_data" => Map.get(review_data, "quote_data"),
      "review" => broker_review,
      "warnings" => broker_warnings(checks)
    }
  end

  defp broker_warnings(checks) when map_size(checks) == 0, do: []

  defp broker_warnings(checks) when is_map(checks) do
    alert_type = Map.get(checks, "alert_type", "BROKER_ALERT")
    details = checks |> Map.delete("alert_type") |> Jason.encode!()
    ["#{alert_type}: #{details}"]
  end

  defp broker_warnings(_checks), do: ["BROKER_ALERT: malformed alert payload"]

  defp preview_fingerprint(arguments, preview) do
    digest =
      {arguments, preview}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "rh-review-" <> digest
  end

  defp money_to_non_negative_cents(value) do
    case money_to_cents(value) do
      {:ok, cents} when cents >= 0 -> {:ok, cents}
      _other -> {:error, :invalid_broker_money}
    end
  end

  defp money_to_cents(value), do: decimal_to_scaled_integer(value, 2)
  defp quantity_to_micros(value), do: decimal_to_scaled_integer(value, 6)

  defp decimal_to_scaled_integer(value, scale) when is_binary(value) do
    with {decimal, ""} <- Decimal.parse(value),
         scaled <- Decimal.mult(decimal, Decimal.new(Integer.pow(10, scale))),
         rounded <- Decimal.round(scaled, 0, :half_up) do
      {:ok, Decimal.to_integer(rounded)}
    else
      _other -> {:error, :invalid_broker_decimal}
    end
  end

  defp decimal_to_scaled_integer(_value, _scale), do: {:error, :invalid_broker_decimal}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _other -> {:error, :invalid_broker_timestamp}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid_broker_timestamp}

  defp regular_market_open?(timestamp) do
    eastern = DateTime.shift_zone!(timestamp, MarketCalendar.zone())
    date = DateTime.to_date(eastern)
    time = DateTime.to_time(eastern)

    MarketCalendar.trading_day?(date) and
      Time.compare(time, ~T[09:30:00]) in [:eq, :gt] and
      Time.compare(time, ~T[16:00:00]) == :lt
  end

  defp multiply_quantity(micros, cents),
    do: div(micros * cents + 999_999, 1_000_000)

  defp format_scaled_integer(value, scale) do
    divisor = Integer.pow(10, scale)
    whole = div(value, divisor)

    fractional =
      value
      |> rem(divisor)
      |> Integer.to_string()
      |> String.pad_leading(scale, "0")
      |> String.trim_trailing("0")

    if fractional == "", do: Integer.to_string(whole), else: "#{whole}.#{fractional}"
  end

  defp blank?(value), do: value in [nil, ""]
end
