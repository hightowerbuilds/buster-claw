# Trading Tab Roadmap

**A top-level Trading tab: the chat beside a real brokerage dashboard — positions with true P&L, real price charts, market context — on our own chart engine**

> Scoped 2026-07-28 against the shipped portfolio ledger
> (PORTFOLIO_HISTORY_ROADMAP, all phases complete), the two-stage Trading panel,
> and the probed Robinhood MCP surface.
>
> Decisions locked at scoping time (operator):
> - **Our own SVG chart engine, extended.** No charting dependency, no
>   attribution logo. Candlesticks, sparklines, and baseline fills are ours to
>   build — the same call as CDP-over-Playwright, made for the same reasons.
>   (TradingView's lightweight-charts was evaluated and declined: 35KB and
>   excellent, but a dependency with a required logo.)
> - **A new top-level `/trading` tab** in the main strip, peer to Home and
>   Browser. The Home "Trading" sub-tab moves **wholesale** — chat, panel,
>   chart, prompts — leaving Home with Chat / Calendar / Notes. One surface,
>   one truth.
> - **All four data panels**: positions with unrealized P&L, per-symbol price
>   charts, day change + market context, earnings.
> - Layout keeps the split: **chat left, dashboard right**, on the existing
>   `SplitResizer`.

**Status 07-28 — SHIPPED, all phases** (archived 07-28 as
`07-28-26-trading-tab-roadmap.md`; originally `TRADING_TAB_ROADMAP.md`, the name
~12 code comments still cite). 0 through 6 landed in one arc
(commits 34dc0e8..4863db8 + the close-out), each phase probed against the live
API before commit. Deviations from the plan as written, all recorded in the
relevant commit:

- **Earnings ride the daily sweep** rather than a separate cached fetch — the
  calendar tool turned out to be market-wide (no symbol filter), so the sweep
  filters to the held set it already discovered, and one-run-per-day held.
- **The activity panel renders on both views** (combined = merged-and-gap-named,
  selected = scoped), not only the dashboard — a promotion that deleted the
  per-account block without losing its information.
- **Chart coverage tolerates one trading day of API lag** — the API doesn't
  materialize today's bar until well after the close (measured twice); without
  the allowance every candle toggle re-spent a ~2-minute run all evening.
- **`position_costs.quantity` is a float**, not the planned numeric-as-string —
  display-only either way, and aggregation across accounts made the string form
  pure friction.
- The **1-in-6 model flake** appeared twice more in new costumes ("tool not
  callable"; unmasked account numbers were already Phase-0 lore) — every
  fetch path retries by design and every parser enforces rather than requests.

Open (deliberate): drag-pan/zoom, intraday, order entry, benchmark overlays —
see "not building" below, unchanged.

---

## Outcome

Open the Trading tab and pass the five-second test: total value and today's
change readable instantly, the gain/loss line beneath, and your holdings listed
the way a brokerage lists them — quantity, price, day change, market value, and
**what you actually paid**, so the unrealized gain is a fact rather than a
feeling. Click a holding and get a real candlestick chart of that stock with
years of dense history. Beside your own numbers, the S&P and Nasdaq, so "was
that me or the market" has an answer. The agent chat rides along, because the
person reading this dashboard is one sentence away from acting on it.

## How far we take it — and where we stop

**We are building:** the routed tab and wholesale migration; a market-data cache
(daily closes, OHLCV on demand, quotes, cost basis, earnings) fed by batched
agent runs; sparklines, candlesticks, and a day-change hero on the extended SVG
engine; per-symbol charts with range controls and the existing crosshair.

**We are not building:**
- **A live intraday chart.** Robinhood's five-second line needs a polling feed;
  our fetches are agent runs costing cents and ~30–90s each. Refresh stays
  explicit and daily. No pump hammers the MCP.
- **Freeform pan/zoom gestures.** Crosshair + range buttons cover reading the
  chart; drag-pan is the expensive half of hand-built charting and is deferred
  until someone actually misses it.
- **Order entry from the dashboard.** Trading happens through the chat — the
  whole safety model (agentic account only, Sentinel line on every send) lives
  there, and a buy button would bypass it.
- **Benchmark overlays as chart series.** Index *quotes* give context; overlaying
  SPY on your portfolio line is an indexed-to-common-base problem and a second
  series with its own honesty questions. Deferred.
- Options chains, watchlist management, screeners.

## Constraints that shape everything

**1. Every number transits a language model — payload size is a correctness
parameter.** The stage-1/2 pipeline runs haiku reading tool results, measured at
~1 failure in 6, and it once returned unmasked account numbers against explicit
instructions. Asking it to transcribe 2,500 OHLCV bars is asking for silent
corruption in the middle of row 1,800. So market data is fetched in two tiers:

  - **Closes tier** — one batched run, all held symbols (`get_equity_historicals`
    takes 10 per call), ~90 daily closes each. Small enough to transcribe
    faithfully; feeds every sparkline and day-change figure.
  - **Chart tier** — one symbol, on demand, when its chart is opened. Interval
    chosen so the transcription stays ≤ ~260 rows (daily for 1Y, weekly for 5Y).

**2. Every fetch costs an agent run.** Cache in SQLite, refresh explicitly, and
let the daily Recorder be the pump: daily bars change once per trading day, and
the Recorder already fires after the close. Never a per-symbol run where a batch
tool exists.

**3. What Robinhood's tools will and won't give** (probed 07-27/28): no
portfolio-value history (our ledger remains the only source — unchanged), no
transfers tool, no crypto positions tool, monthly realized buckets, and
`get_equity_tax_lots` is **one symbol per call** — cost basis for N holdings is
N tool calls inside one run, which is fine at three holdings and worth
rechecking at thirty.

**4. The extraction is the risky phase, not the features.** `StatusLive` is
~2,000 lines with trading woven through it (assigns, asyncs, sub-tab switching,
unread dots, the pinned DB-less conversation). Phase 0 moves it whole and moves
its tests with it; every later phase builds on clean ground.

## Data model

Money is integer cents. API-sourced market data is a **cache of someone else's
truth** — it carries `as_of` and is refreshed wholesale, never merged with
model-remembered values.

```
symbol_bars                       price history cache (both tiers)
  symbol        string
  bar_on        date
  close_cents   integer           always present
  open_cents / high_cents / low_cents   integers, null for closes-tier rows
  volume        integer, null for closes-tier rows
  unique (symbol, bar_on)         chart-tier upsert fills OHLC over a close

position_costs                    aggregated from get_equity_tax_lots
  account_key   string            last4, as everywhere in the ledger
  symbol        string
  quantity      numeric-as-string (fractional shares; display only)
  cost_basis_cents  integer       Σ lots
  lots          integer
  as_of         utc_datetime
  unique (account_key, symbol)

quotes / indexes / earnings       Settings JSON blobs (browser_tabs precedent)
  each carries fetched_at; staleness rules per panel (quotes 15m, earnings daily)
```

## Phases

### Phase 0 — The tab, and the move

Route `live "/trading", TradingLive` (router.ex); dock + tab-strip entry in
`layouts.ex` `@navigation_items`. TradingLive takes the split layout and
**everything** the Home sub-tab owns today: the pinned conversation
(`Chat.subscribe(Trading.conv_id())`), stage-1/2 fetching, account chips +
exclude, anomaly prompt, the chart, the table, the backfill button. StatusLive
loses every `trading_*` assign, event, and async; the Home tab row becomes
Chat / Calendar / Notes; the trading-unread dot logic goes. The
`status_live_test` trading describe blocks move to `trading_live_test`.

**Done when:** `/trading` does everything the sub-tab did (same tests, new
home); `grep trading_ lib/buster_claw_web/live/status_live.ex` is empty; the
dock shows Trading; `mix precommit` green.

### Phase 1 — The market-data spine

`symbol_bars` migration; closes-tier prompt (batched, held symbols, 90 daily
closes each) + parser with the ledger's sanity posture; quotes + index-quotes
cached blob; Recorder extension — after filing balances it refreshes closes and
quotes, so the data is waiting before anyone opens the tab.

**Done when:** one agent run populates bars for every held symbol; a second run
the same day writes nothing new; the Recorder path is covered by tests with a
stubbed fetcher; no UI yet.

### Phase 2 — The hero row

Total value, **day change $ and %** computed from the ledger (today vs the
previous reading — a missing yesterday says "no reading yesterday", never $0.00
or a guess), SPY / QQQ chips from the index cache with their own day change.
The gain/loss chart keeps its place under the hero. No intraday line — we have
no intraday history and won't fake one.

**Done when:** the five-second test passes; day change agrees with the ledger's
two most recent readings; index chips carry as-of.

### Phase 3 — Positions, with what you paid

Tax-lots fetch (one run per account, all symbols inside), `position_costs`;
the positions panel: symbol, quantity, price, day Δ, market value, **unrealized
P&L $ and %**, and a sparkline from the closes tier — same lookback window on
every row, so the glyphs are comparable. Missing cost basis renders "cost basis
not loaded" with a fetch control — **never $0**, which would claim you paid
nothing. Rows aggregate across included accounts, tagged by account; the
exclusion set applies here exactly as it does to the totals.

**Done when:** the panel shows real unrealized P&L for real holdings; a holding
without lots says so; sparklines render from cached closes with no fetch on tab
open.

### Phase 4 — Symbol charts

Click a position → the chart pane switches to that symbol. Chart-tier fetch on
demand (bounded rows, interval by range: 1M/3M daily, 1Y daily, 5Y weekly);
SVG **candlestick** renderer (up/down on the validated success/error tokens,
with OHLC written in the readout — never color alone) plus a line/area mode;
the existing crosshair/keyboard/readout hook generalized to price series; range
buttons per symbol. Price charts do **not** force zero into frame — that rule is
for gain lines; a $300 stock charted from $0 is unreadable. Domain is padded
min/max, and the y-axis labels say so.

**Done when:** a real holding renders candles from real bars; ranges change
interval honestly (and say which); the readout speaks OHLC; "Portfolio" returns
to the gain/loss line.

### Phase 5 — Events and activity

Earnings strip from `get_earnings_calendar` for held symbols ("GOOGL reports
Thu"), cached daily; recent trades panel from the existing stage-2 orders data,
promoted out of the per-account card into the dashboard.

**Done when:** upcoming earnings for held symbols show with dates; an empty
calendar says "no earnings scheduled" not nothing.

### Phase 6 — Retire and record

Kill any dead code the migration stranded; `scripts/check_docs_drift.sh`;
ARCHITECTURE.md gains a line for the tab; daily summary; the Home sub-tab's
memory of trading is fully gone.

## Honesty rules

1. **Never ask the model to transcribe more than it can carry.** Bounded rows
   per run, always; the two-tier split exists for this.
2. **Cost basis absent ≠ cost basis zero.** "Not loaded" is a state with words.
3. **Day change requires yesterday.** No reading yesterday → say so.
4. **Cached market data carries as-of, everywhere it renders.**
5. **Sparklines share one lookback window** across rows, or they aren't
   comparable and become decoration.
6. **Price charts pad their domain; gain charts keep zero in frame.** Two rules
   because they answer two questions.
7. **Sign is written, never carried by color alone** — unchanged from the chips
   and the P&L chart.
8. **Exclusions apply and are disclosed** on every aggregated surface, including
   positions.

## Risks

| Risk | Mitigation |
|---|---|
| StatusLive extraction breaks the pinned chat or unread flows | Tests move first and must pass unchanged; Phase 0 ships alone |
| Haiku mis-transcribes numeric tables | Bounded payloads; per-row shape validation; ledger-style refusal over persistence of garbage |
| Tax lots at N holdings = N calls in one run | Fine at 3 holdings; recheck the run duration if the portfolio grows past ~15 |
| A symbol the tools can't chart (delisted, crypto) | Skip with a worded state, exactly like crypto holdings today |
| Two chart code paths (gain vs price) drift | One shared geometry/crosshair core; series-specific rules live in explicit variant modules |

## Open questions

- **Sparkline lookback** — 30 days to start; revisit when there's a month of
  closes to look at.
- **Quotes freshness** — 15-minute staleness mirrors the account snapshot; the
  operator may want a manual refresh-all control on the hero.
- **Where the flows/anomaly UI lands** long-term — it moves as-is in Phase 0;
  whether it belongs on the chart or near the account chips can be judged once
  the dashboard exists.

## References (research, 07-28)

- [tradingview/lightweight-charts](https://github.com/tradingview/lightweight-charts)
  — evaluated engine; declined for the dependency + attribution, kept as the
  benchmark for what our SVG should feel like (baseline series, whitespace gaps).
- [Investment dashboard UX principles](https://lollypop.design/blog/2026/may/investment-dashboard-ux-design-guide/)
  — hierarchy: value → change → drill-down; five-second rule.
- [Trader dashboard practices](https://chartswatcher.com/pages/blog/top-dashboard-design-best-practices-for-traders-in-2025)
  — progressive disclosure, glanceable day change.
