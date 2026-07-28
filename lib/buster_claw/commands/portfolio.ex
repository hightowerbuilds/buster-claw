defmodule BusterClaw.Commands.Portfolio do
  @moduledoc """
  Portfolio-history commands (PORTFOLIO_HISTORY_ROADMAP Phase 6). Delegated to
  from `BusterClaw.Commands`.

  Gives the agent the same series the chart draws, so "how did I do this week"
  is answerable from the terminal without opening the tab — and, more usefully,
  without a second implementation of the gain math that could disagree with the
  first.

  Every reply is dollars, not cents: the ledger stores integers to keep its own
  arithmetic exact, but a command surface that returned `21740` for $217.40
  would invite exactly the units error the ledger's own gate exists to catch.

  `portfolio_flow_add` is the only mutating command here, and it is `:restricted`
  — it changes what every past and future gain figure means.
  """

  alias BusterClaw.MarketCalendar
  alias BusterClaw.Portfolio
  alias BusterClawWeb.PortfolioChart

  @doc """
  The cumulative gain/loss series, optionally windowed and scoped to one account.

  `cumulative` is the change across the requested range, re-zeroed at its start
  — `range: "ALL"` is therefore the since-inception figure, and `range: "1M"`
  is the past month's.

  Args: `range` (1W/1M/3M/1Y/ALL, default ALL), `account` (last four digits;
  omit for the combined total).
  """
  def portfolio_history(args \\ %{}) do
    range = Map.get(args, "range", "ALL")

    full =
      case Map.get(args, "account") do
        nil -> Portfolio.total_cumulative_series()
        "" -> Portfolio.total_cumulative_series()
        key -> Portfolio.cumulative_series(to_string(key))
      end

    # Windowed AND re-zeroed against what the window inherited, exactly as the
    # chart does — `cumulative` is change across the requested range, not since
    # inception. The two surfaces read the same ledger and must not disagree
    # about what the number means.
    series = full |> PortfolioChart.window(range) |> PortfolioChart.rebase(full)

    {:ok,
     %{
       range: range,
       account: Map.get(args, "account"),
       points: Enum.map(series, &point_payload/1),
       # Coverage rides along with the data rather than sitting in a doc
       # somewhere: a caller summing an understated realized segment should be
       # told so in the same breath.
       coverage: Portfolio.backfill_coverage(),
       as_of: MarketCalendar.today() |> Date.to_iso8601()
     }}
  end

  defp point_payload(point) do
    %{
      day: Date.to_iso8601(point.day),
      cumulative: Portfolio.to_dollars(point.cumulative_cents),
      change: point.gain_cents && Portfolio.to_dollars(point.gain_cents),
      value: point.value_cents && Portfolio.to_dollars(point.value_cents),
      transfer: dollars_or_nil(Map.get(point, :flow_cents, 0)),
      # `realized` points come from Robinhood and see closed trades only;
      # `recorded` points are ours and see unrealized movement too. A caller
      # comparing them without knowing that is comparing two different things.
      measure: to_string(point.measure)
    }
  end

  defp dollars_or_nil(0), do: nil
  defp dollars_or_nil(cents), do: Portfolio.to_dollars(cents)

  @doc "Deposits, withdrawals, and reviewed-not-a-transfer days for one account."
  def portfolio_flow_list(%{"account" => key}) when is_binary(key) and key != "" do
    flows =
      key
      |> Portfolio.flows()
      |> Enum.map(
        &%{
          day: Date.to_iso8601(&1.occurred_on),
          amount: Portfolio.to_dollars(&1.amount_cents),
          kind: &1.kind,
          note: &1.note,
          source: &1.source
        }
      )

    {:ok, %{account: key, flows: flows}}
  end

  def portfolio_flow_list(_args), do: {:error, :missing_account}

  @doc """
  Record a transfer (or mark a day as genuinely not one).

  `amount` is a magnitude in dollars; the sign is taken from `kind`, so a caller
  cannot produce a withdrawal that adds to the gain it was meant to remove.
  """
  def portfolio_flow_add(%{"account" => key, "day" => day, "kind" => kind} = args)
      when is_binary(key) and key != "" do
    with {:ok, day} <- parse_day(day),
         {:ok, cents} <- signed_cents(kind, Map.get(args, "amount")),
         {:ok, flow} <-
           Portfolio.put_flow(%{
             account_key: key,
             occurred_on: day,
             amount_cents: cents,
             kind: kind,
             note: Map.get(args, "note"),
             source: "agent"
           }) do
      {:ok,
       %{
         account: key,
         day: Date.to_iso8601(flow.occurred_on),
         amount: Portfolio.to_dollars(flow.amount_cents),
         kind: flow.kind
       }}
    end
  end

  def portfolio_flow_add(_args), do: {:error, :missing_account}

  defp parse_day(day) when is_binary(day) do
    case Date.from_iso8601(day) do
      {:ok, parsed} -> {:ok, parsed}
      _error -> {:error, :bad_day}
    end
  end

  defp parse_day(_day), do: {:error, :bad_day}

  defp signed_cents("not_a_transfer", _amount), do: {:ok, 0}

  defp signed_cents(kind, amount) when kind in ["deposit", "withdrawal"] do
    case to_number(amount) do
      {:ok, dollars} when dollars > 0 ->
        cents = round(dollars * 100)
        {:ok, if(kind == "withdrawal", do: -cents, else: cents)}

      _other ->
        {:error, :bad_amount}
    end
  end

  defp signed_cents(_kind, _amount), do: {:error, :bad_kind}

  defp to_number(amount) when is_number(amount), do: {:ok, amount}

  defp to_number(amount) when is_binary(amount) do
    case Float.parse(amount) do
      {number, _rest} -> {:ok, number}
      :error -> {:error, :bad_amount}
    end
  end

  defp to_number(_amount), do: {:error, :bad_amount}
end
