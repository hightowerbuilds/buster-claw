defmodule BusterClawWeb.TradingView do
  @moduledoc """
  The Trading dashboard's view model: broker data in, render-ready values out.

  Everything here is a pure function of its arguments — no socket, no assigns,
  no process state. That is the whole charter, and it is what makes these
  testable without booting a LiveView: the state classifiers (`detail_state/2`
  and the `*_dataset_state` family) decide what a panel is allowed to claim,
  and the formatters decide how it reads.

  `TradingLive` imports this module, so its templates call these by bare name.
  """

  alias BusterClaw.DataState
  alias BusterClaw.Portfolio
  alias BusterClaw.Trading

  # How old a holdings read may be before an EMPTY one stops counting as a
  # confirmation. This only ever gates the wording of "no positions — all cash":
  # everything else says its age and lets the reader judge. Twelve hours, not
  # minutes — holdings are fetched by an explicit agent run, so a 15-minute
  # threshold marked every panel stale within a quarter hour of the only refresh
  # the user ever asks for, which is an alarm that is always ringing.
  @holdings_stale_min 12 * 60

  @doc "The snapshot inside an account fetch state, whatever stage it is in."
  def last_snapshot({:ok, snap}), do: snap
  def last_snapshot({:loading, prev}), do: prev
  def last_snapshot({:error, _reason, prev}), do: prev
  def last_snapshot(_), do: nil

  @doc "The rows a DataState carries, or `[]`."
  def state_data(%DataState{data: data}) when is_list(data), do: data
  def state_data(%DataState{}), do: []

  # Range -> (window, interval). 5Y is weekly because ~260 rows is the most
  # transcription one run may carry; the disclosure line says which is showing.
  def symbol_window("1M"), do: {31, "day"}
  def symbol_window("3M"), do: {93, "day"}
  def symbol_window("1Y"), do: {366, "day"}
  def symbol_window("5Y"), do: {1830, "week"}

  # Collapse (account, in-flight stage-2 state) into the one thing the template
  # renders. Order matters: unreadable beats in-flight beats failed beats
  # loaded, because an account with no positions tool is never "loading".
  def detail_state(nil, _detail), do: :unsupported

  def detail_state(%{"holdings_supported" => false}, _detail), do: :unsupported
  def detail_state(%{"identity_ambiguous" => true}, _detail), do: :ambiguous

  def detail_state(account, detail) do
    id = account["id"]

    case detail do
      {:loading, ^id} ->
        :loading

      {:error, ^id, reason} ->
        {:error, reason}

      _ ->
        cond do
          not Trading.detail_loaded?(account) -> :loading
          sorted_positions(account) == [] -> :empty
          true -> :loaded
        end
    end
  end

  def account_dataset_state(nil),
    do: DataState.unavailable(:not_loaded, source: :brokerage_accounts)

  def account_dataset_state({:loading, prev}) do
    DataState.loading(prev,
      as_of: snapshot_fetched_at(prev),
      source: :brokerage_accounts
    )
  end

  def account_dataset_state({:ok, snap}) do
    DataState.cached(snap, Trading.snapshot_stale?(snap),
      as_of: snapshot_fetched_at(snap),
      source: :brokerage_accounts
    )
  end

  def account_dataset_state({:error, reason, nil}),
    do: DataState.unavailable(reason, source: :brokerage_accounts)

  def account_dataset_state({:error, reason, prev}) do
    DataState.stale(prev,
      as_of: snapshot_fetched_at(prev),
      reason: reason,
      source: :brokerage_accounts
    )
  end

  def detail_dataset_state(_account, :unsupported),
    do: DataState.unavailable(:unsupported, source: :brokerage_positions)

  def detail_dataset_state(_account, :ambiguous),
    do: DataState.unavailable(:ambiguous_identity, source: :brokerage_positions)

  def detail_dataset_state(account, :loading) do
    DataState.loading(nil,
      as_of: detail_fetched_at(account),
      source: :brokerage_positions
    )
  end

  def detail_dataset_state(_account, {:error, reason}),
    do: DataState.unavailable(reason, source: :brokerage_positions)

  def detail_dataset_state(account, state) when state in [:empty, :loaded] do
    rows = sorted_positions(account)
    as_of = detail_fetched_at(account)
    stale? = datetime_stale?(as_of)

    if state == :empty and not stale? do
      DataState.confirmed_empty(as_of: as_of, source: :brokerage_positions)
    else
      DataState.cached(rows, stale?,
        as_of: as_of,
        source: :brokerage_positions
      )
    end
  end

  defp snapshot_fetched_at(%{"fetched_at" => stamp}) when is_binary(stamp),
    do: parse_datetime(stamp)

  defp snapshot_fetched_at(_snap), do: nil

  defp detail_fetched_at(%{"detail_at" => stamp}) when is_binary(stamp),
    do: parse_datetime(stamp)

  defp detail_fetched_at(_account), do: nil

  def detail_error({:error, :broker_tools_unavailable}),
    do: "Robinhood tools unavailable — run `claude mcp login robinhood`"

  def detail_error({:error, {:robinhood, msg}}), do: msg
  def detail_error({:error, :bad_snapshot}), do: "unreadable response"
  def detail_error({:error, :unidentifiable_account}), do: "account number unavailable"
  def detail_error({:error, :ambiguous_account}), do: "account identity is ambiguous"
  def detail_error({:error, {:agent_exit, status}}), do: "agent exited #{status}"
  def detail_error({:error, :no_agent_cli}), do: "Claude Code CLI not found"
  def detail_error(_state), do: "agent run failed"

  # The headline total must agree with the chart it sits above. Once an account
  # is excluded, summing every account would show a number the line never draws.
  def included_total(snap, excluded) do
    snap
    |> Trading.accounts()
    |> Enum.reject(&(Trading.account_key(&1) in excluded))
    |> Enum.map(& &1["value"])
    |> Enum.filter(&is_number/1)
    |> Enum.sum()
  end

  def money(v) when is_number(v), do: "$" <> :erlang.float_to_binary(v * 1.0, decimals: 2)
  def money(_v), do: "—"

  # Cents to a signed dollar string. The sign is WRITTEN, never left to color —
  # the same rule the buy/sell chips follow.
  def signed_money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: "+"
    sign <> money(abs(cents) / 100)
  end

  def signed_money(_cents), do: "—"

  # " (+1.40%)" — appended to the day-change dollars; empty when the base was
  # zero and no percentage exists.
  def pct_suffix(nil), do: ""
  def pct_suffix(pct), do: " (#{signed_pct(pct)})"

  def signed_pct(pct) when is_number(pct) do
    sign = if pct < 0, do: "-", else: "+"
    sign <> :erlang.float_to_binary(abs(pct) * 1.0, decimals: 2) <> "%"
  end

  # The activity panel's rows: `:hidden`, or %{orders: [{order, account_label}],
  # note: nil | "…"}. Selected view shows that account's orders under the same
  # gating its holdings use; the combined view merges every LOADED account and
  # names the gap when some aren't.
  def activity_rows(accounts, excluded, nil = _selected, _detail_state) do
    eligible =
      accounts
      |> Enum.filter(
        &(&1["holdings_supported"] and is_binary(Trading.account_key(&1)) and
            Trading.account_key(&1) not in excluded)
      )

    loaded = Enum.filter(eligible, &Trading.detail_loaded?/1)

    orders =
      loaded
      |> Enum.flat_map(fn account ->
        account["orders"]
        |> List.wrap()
        |> Enum.map(&{&1, account["label"]})
      end)
      |> Enum.sort_by(fn {order, _label} -> order["placed_at"] || "" end, :desc)
      |> Enum.take(8)

    cond do
      eligible == [] ->
        %{
          orders: [],
          note: "no supported included accounts",
          state: DataState.unavailable(:no_supported_accounts, source: :brokerage_orders)
        }

      loaded == [] ->
        %{
          orders: [],
          note: "0 of #{length(eligible)} accounts loaded",
          state: DataState.unavailable(:not_loaded, source: :brokerage_orders)
        }

      length(loaded) < length(eligible) ->
        %{
          orders: orders,
          note: "partial · #{length(loaded)} of #{length(eligible)} accounts",
          state:
            DataState.unavailable(:partial,
              data: orders,
              as_of: oldest_detail_at(loaded),
              source: :brokerage_orders
            )
        }

      true ->
        %{orders: orders, note: nil, state: activity_dataset_state(orders, loaded)}
    end
  end

  def activity_rows(_accounts, _excluded, selected, detail_state) do
    cond do
      detail_state == :loading ->
        %{
          orders: [],
          note: "loading selected account",
          state: DataState.loading(nil, source: :brokerage_orders)
        }

      detail_state in [:unsupported, :ambiguous] or match?({:error, _}, detail_state) ->
        %{
          orders: [],
          note: "selected account order history unavailable",
          state: DataState.unavailable(:not_readable, source: :brokerage_orders)
        }

      true ->
        orders = selected["orders"] |> List.wrap() |> Enum.map(&{&1, selected["label"]})

        %{
          orders: orders,
          note: nil,
          state: activity_dataset_state(orders, [selected])
        }
    end
  end

  defp activity_dataset_state(orders, accounts) do
    as_of = oldest_detail_at(accounts)
    stale? = datetime_stale?(as_of)

    if orders == [] and not stale? do
      DataState.confirmed_empty(as_of: as_of, source: :brokerage_orders)
    else
      DataState.cached(orders, stale?, as_of: as_of, source: :brokerage_orders)
    end
  end

  defp oldest_detail_at(accounts) do
    accounts
    |> Enum.map(&detail_fetched_at/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      dates -> Enum.min(dates, DateTime)
    end
  end

  def activity_order_sections(orders) do
    {fills, other} =
      Enum.split_with(orders, fn {order, _account_label} -> order["state"] == "filled" end)

    [
      {"Orders (not filled)", other},
      {"Fills (from filled-order status)", fills}
    ]
  end

  def transfer_activity(accounts, excluded, selected) do
    keys =
      case selected do
        nil ->
          accounts
          |> Enum.map(&Trading.account_key/1)
          |> Enum.reject(&(is_nil(&1) or &1 in excluded))

        account ->
          List.wrap(Trading.account_key(account))
      end

    if keys == [] do
      %{
        rows: [],
        state: DataState.unavailable(:no_identifiable_accounts, source: :manual_transfer_ledger)
      }
    else
      rows =
        Portfolio.all_flows()
        |> Enum.filter(&(&1.account_key in keys))
        |> Enum.sort_by(& &1.occurred_on, {:desc, Date})
        |> Enum.take(8)

      state =
        case rows do
          [] ->
            DataState.confirmed_empty(source: :manual_transfer_ledger)

          [latest | _] ->
            DataState.fresh(rows,
              as_of: latest.occurred_on,
              source: :manual_transfer_ledger
            )
        end

      %{rows: rows, state: state}
    end
  end

  def earnings_when(%Date{} = date) do
    today = BusterClaw.MarketCalendar.today()

    case Date.diff(date, today) do
      0 -> "today"
      1 -> "tomorrow"
      _ -> Elixir.Calendar.strftime(date, "%a %b %-d")
    end
  end

  def money_cents(cents) when is_integer(cents), do: money(cents / 100)
  def money_cents(_cents), do: "—"

  # Fractional shares, floats for display only — trimmed so 0.1 + 0.2 never
  # renders its float dust.
  def qty(quantity) when is_float(quantity) do
    if quantity == trunc(quantity),
      do: Integer.to_string(trunc(quantity)),
      else: quantity |> Float.round(4) |> Float.to_string()
  end

  def qty(quantity), do: to_string(quantity)

  def position_day_class(nil), do: "text-base-content/40"
  def position_day_class(pct) when pct < 0, do: "text-error"
  def position_day_class(_pct), do: "text-success"

  # An index level, not a dollar amount — no currency mark.
  def index_price(price) when is_number(price),
    do: :erlang.float_to_binary(price * 1.0, decimals: 2)

  def index_price(_price), do: "—"

  def index_change(nil), do: "—"
  def index_change(pct), do: signed_pct(pct)

  def index_change_class(nil), do: "text-base-content/40"
  def index_change_class(pct) when pct < 0, do: "text-error"
  def index_change_class(_pct), do: "text-success"

  def sorted_positions(%{"positions" => positions}),
    do: Enum.sort_by(List.wrap(positions), &(-position_value(&1)))

  def sorted_positions(_account), do: []

  # Bar length as a % of the largest position IN THAT ACCOUNT (allocation is
  # per-account — scaling a Roth holding against an Investing holding would
  # compare two things the user never asked to compare). Guarded so a
  # zero/garbage value can't divide by zero or overflow the track.
  def bar_width(pos, account) do
    max =
      account
      |> sorted_positions()
      |> Enum.map(&position_value/1)
      |> Enum.max(fn -> 0 end)

    if max > 0, do: Float.round(position_value(pos) / max * 100, 1), else: 0
  end

  defp position_value(%{"value" => v}) when is_number(v) and v > 0, do: v
  defp position_value(_pos), do: 0

  # Buy/sell chips: status colors validated vs both surfaces (CVD ΔE 9.7 dark /
  # 7.4 light); the written BUY/SELL word is the required secondary encoding.
  def order_side_class("buy"), do: "border-success/50 text-success"
  def order_side_class("sell"), do: "border-error/50 text-error"
  def order_side_class(_side), do: "border-base-content/30 text-base-content/60"

  def order_when(%{"placed_at" => stamp}) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _} -> relative_time(at)
      _ -> ""
    end
  end

  def order_when(_order), do: ""

  # The 07-28 failure mode gets its own line: the run answered, it just answered
  # without ever reaching the broker. "agent run failed" would understate it.
  def card_error({:error, :broker_tools_unavailable, _prev}),
    do: "Robinhood tools unavailable — run `claude mcp login robinhood`"

  def card_error({:error, {:robinhood, msg}, _prev}), do: msg
  def card_error({:error, :bad_snapshot, _prev}), do: "unreadable snapshot"
  def card_error({:error, {:agent_exit, status}, _prev}), do: "agent exited #{status}"
  def card_error({:error, :no_agent_cli, _prev}), do: "Claude Code CLI not found"
  def card_error({:error, _reason, _prev}), do: "agent run failed"

  # The as-of IS the status line. An age ("as of 3h") carries everything a
  # `stale` badge would, without asking the user to learn a second vocabulary —
  # and it degrades gracefully, where a badge that is on permanently (which
  # `stale` was, at a 15-minute threshold against data refreshed by an explicit
  # agent run) stops being read at all.
  #
  # The distinctions a timestamp genuinely cannot carry — "we asked and got
  # nothing back" versus "we never asked" — are the panel's own empty-state
  # sentence, one line lower. That is the right place for them: they only matter
  # when there is nothing else on screen.
  def as_of_label(%DataState{status: :loading}), do: "updating…"
  def as_of_label(%DataState{status: :unavailable}), do: ""
  def as_of_label(%DataState{as_of: nil}), do: ""
  def as_of_label(%DataState{as_of: as_of}), do: "as of #{format_data_time(as_of)}"

  # Parenthetical for an empty-state sentence, where the age qualifies a claim
  # ("no positions — as of when?") rather than labelling a panel.
  def as_of_suffix(%DataState{as_of: nil}), do: ""
  def as_of_suffix(%DataState{as_of: as_of}), do: " (as of #{format_data_time(as_of)})"

  defp format_data_time(%DateTime{} = at), do: relative_time(at)
  defp format_data_time(%Date{} = day), do: Date.to_iso8601(day)

  defp parse_datetime(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  def datetime_stale?(nil), do: true

  def datetime_stale?(%DateTime{} = at),
    do: DateTime.diff(DateTime.utc_now(), at, :minute) >= @holdings_stale_min

  # A coarse relative timestamp ("3m", "2h", "5d"); older than a week falls back
  # to a short date. Stamps are UTC; so is utc_now.
  defp relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "now"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      seconds < 604_800 -> "#{div(seconds, 86_400)}d"
      true -> Elixir.Calendar.strftime(dt, "%b %-d")
    end
  end
end
