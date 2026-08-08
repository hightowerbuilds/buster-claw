defmodule BusterClaw.Commands.Catalog.Finance do
  @moduledoc """
  Catalog entries: finance research (read-only; every result carries source +
  as-of).
  """

  @doc "Finance catalog entries."
  def entries,
    do: [
      # Finance (read-only research; every result carries source + as-of)
      %{
        name: "finance_sources",
        type: :read,
        tier: :safe,
        description:
          "The financial-data source registry: what this app can reach, its terms, and how " <>
            "far each one has been verified. Optional `status` filters to verified/candidate/" <>
            "blocked/unsanctioned/dead.",
        args: %{"status" => %{type: :string, required: false}}
      },
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
      }
    ]
end
