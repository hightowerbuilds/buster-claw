defmodule BusterClaw.Commands.Catalog.Finance do
  @moduledoc """
  Catalog entries: finance research (read-only; every result carries source +
  as-of) and the portfolio-history ledger.
  """

  @doc "Finance catalog entries."
  def entries,
    do: [
      # Finance (read-only research; every result carries source + as-of)
      %{
        name: "finance_filings",
        type: :read,
        tier: :safe,
        description: "Recent SEC EDGAR filings for a ticker (10-K/10-Q/8-K …), newest first.",
        args: %{"symbol" => %{type: :string, required: true}}
      },
      %{
        name: "finance_fundamentals",
        type: :read,
        tier: :safe,
        description: "Latest SEC XBRL fundamentals for a ticker (revenue, net income, assets …).",
        args: %{"symbol" => %{type: :string, required: true}}
      },
      %{
        name: "finance_quote",
        type: :read,
        tier: :safe,
        description: "Latest quote for a ticker (Finnhub; needs FINNHUB_API_KEY). Carries as-of.",
        args: %{"symbol" => %{type: :string, required: true}}
      },
      %{
        name: "finance_news",
        type: :read,
        tier: :safe,
        description: "Recent company news for a ticker (Finnhub; needs FINNHUB_API_KEY).",
        args: %{"symbol" => %{type: :string, required: true}}
      },
      # Portfolio history (PORTFOLIO_HISTORY_ROADMAP Phase 6). The reads are
      # :safe — they expose the user's own recorded balances back to them, and
      # nothing leaves the machine.
      %{
        name: "portfolio_history",
        type: :read,
        tier: :safe,
        description:
          "Cumulative gain/loss over time. Points before recording began are realized trades only; after, realized + unrealized. Amounts in dollars.",
        args: %{
          "range" => %{type: :string, required: false},
          "account" => %{type: :string, required: false}
        }
      },
      %{
        name: "portfolio_flow_list",
        type: :read,
        tier: :safe,
        description:
          "Deposits and withdrawals recorded against one account (by last four digits).",
        args: %{"account" => %{type: :string, required: true}}
      },
      %{
        name: "portfolio_flow_add",
        type: :mutate,
        tier: :restricted,
        description:
          "Record a deposit/withdrawal, or mark a day as not a transfer. Changes what every gain figure means, so it is restricted.",
        args: %{
          "account" => %{type: :string, required: true},
          "day" => %{type: :string, required: true},
          "kind" => %{type: :string, required: true},
          "amount" => %{type: :string, required: false},
          "note" => %{type: :string, required: false}
        }
      }
    ]
end
