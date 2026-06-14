defmodule BusterClaw.Finance do
  @moduledoc """
  Read-only financial research context. Backs the safe `finance_*` commands and
  (later) the `finance` integration poller / `watchlist_research` cron.

  Design rules (see `projects/financial-advisor/build-roadmap.md`):

  - **Read-only.** No order/trade surface anywhere — these are pure GETs.
  - **Provenance always.** Every result carries `source`, `source_url`, and an
    `as_of` timestamp; per-figure facts carry their own `as_of`. Callers must
    never present a number without its source.

  Phase 1 wires SEC EDGAR (free, no key) for filings + fundamentals. Quotes/news
  (Finnhub, key-gated) land in a later slice.
  """

  alias BusterClaw.Finance.{Edgar, Finnhub}

  @doc "Recent SEC filings for a ticker symbol."
  def filings(symbol, opts \\ []), do: Edgar.filings(symbol, opts)

  @doc "Latest curated XBRL fundamentals for a ticker symbol."
  def fundamentals(symbol, opts \\ []), do: Edgar.fundamentals(symbol, opts)

  @doc "Latest quote for a ticker symbol (Finnhub; key-gated)."
  def quote(symbol, opts \\ []), do: Finnhub.quote(symbol, opts)

  @doc "Recent company news for a ticker symbol (Finnhub; key-gated)."
  def news(symbol, opts \\ []), do: Finnhub.news(symbol, opts)
end
