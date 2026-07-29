defmodule BusterClaw.TradingOrders.Policy do
  @moduledoc """
  Deterministic pre-trade policy checks.

  Defaults are intentionally conservative and can be tightened in application
  configuration. A broker review must be recent and complete; missing facts
  block the order instead of being treated as zero.
  """

  alias BusterClaw.MarketCalendar
  alias BusterClaw.TradingOrders.OrderIntent

  @default_max_notional_cents 100_000
  @default_max_concentration_bps 2_500
  @default_quote_age_seconds 30

  @doc "Validate a structured broker review against local risk policy."
  def check(%OrderIntent{} = intent, review, opts \\ []) when is_map(review) do
    policy = Keyword.get(opts, :policy, configured_policy())
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- fresh_review(review, now, policy),
         :ok <- symbol_allowed(intent.symbol, policy),
         :ok <- within_notional(review.estimated_notional_cents, policy),
         :ok <- within_concentration(intent, review.concentration_bps, policy),
         :ok <- enough_buying_power(intent, review) do
      allowed_market_hours(intent, review, now, policy)
    end
  end

  defp configured_policy do
    defaults = [
      max_notional_cents: @default_max_notional_cents,
      max_concentration_bps: @default_max_concentration_bps,
      max_quote_age_seconds: @default_quote_age_seconds,
      blocked_symbols: [],
      allow_market_orders_outside_hours: false
    ]

    Keyword.merge(defaults, Application.get_env(:buster_claw, :trading_order_policy, []))
  end

  defp fresh_review(%{broker_timestamp: %DateTime{} = timestamp}, now, policy) do
    age = DateTime.diff(now, timestamp, :second)
    max_age = Keyword.fetch!(policy, :max_quote_age_seconds)

    cond do
      age < -5 -> {:error, :broker_timestamp_in_future}
      age > max_age -> {:error, :stale_broker_review}
      true -> :ok
    end
  end

  defp fresh_review(_review, _now, _policy), do: {:error, :missing_broker_timestamp}

  defp symbol_allowed(symbol, policy) do
    blocked =
      policy
      |> Keyword.fetch!(:blocked_symbols)
      |> Enum.map(&String.upcase/1)

    if symbol in blocked, do: {:error, :symbol_blocked}, else: :ok
  end

  defp within_notional(cents, policy)
       when is_integer(cents) and cents > 0 do
    if cents <= Keyword.fetch!(policy, :max_notional_cents),
      do: :ok,
      else: {:error, :notional_limit_exceeded}
  end

  defp within_notional(_cents, _policy), do: {:error, :invalid_estimated_notional}

  defp within_concentration(%OrderIntent{side: "sell"}, _bps, _policy), do: :ok

  defp within_concentration(%OrderIntent{}, bps, policy)
       when is_integer(bps) and bps >= 0 do
    if bps <= Keyword.fetch!(policy, :max_concentration_bps),
      do: :ok,
      else: {:error, :concentration_limit_exceeded}
  end

  defp within_concentration(_intent, _bps, _policy), do: {:error, :missing_concentration}

  defp enough_buying_power(%OrderIntent{side: "sell"}, _review), do: :ok

  defp enough_buying_power(%OrderIntent{side: "buy"}, %{
         buying_power_cents: buying_power,
         estimated_notional_cents: notional
       })
       when is_integer(buying_power) and is_integer(notional) do
    if buying_power >= notional, do: :ok, else: {:error, :insufficient_buying_power}
  end

  defp enough_buying_power(_intent, _review), do: {:error, :missing_buying_power}

  defp allowed_market_hours(%OrderIntent{order_type: "limit"}, _review, _now, _policy), do: :ok

  defp allowed_market_hours(
         %OrderIntent{order_type: "market"},
         %{market_open: broker_market_open?},
         now,
         policy
       )
       when is_boolean(broker_market_open?) do
    override? = Keyword.fetch!(policy, :allow_market_orders_outside_hours)

    if override? or (broker_market_open? and market_open?(now)),
      do: :ok,
      else: {:error, :market_closed}
  end

  defp allowed_market_hours(%OrderIntent{order_type: "market"}, _review, _now, _policy),
    do: {:error, :missing_market_state}

  defp market_open?(%DateTime{} = now) do
    eastern = DateTime.shift_zone!(now, MarketCalendar.zone())
    date = DateTime.to_date(eastern)
    time = DateTime.to_time(eastern)

    MarketCalendar.trading_day?(date) and
      Time.compare(time, ~T[09:30:00]) in [:eq, :gt] and
      Time.compare(time, ~T[16:00:00]) == :lt
  end
end
