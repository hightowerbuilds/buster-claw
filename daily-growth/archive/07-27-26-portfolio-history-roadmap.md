# Portfolio History Roadmap

**A gain/loss chart for the account total — day by day, zoomable to years**

> Scoped 2026-07-27 against the shipped two-stage Trading panel
> (`BusterClaw.Trading`, `StatusLive.trading_account_card/1`) and the live
> Robinhood agentic MCP surface, probed the same day.
>
> Decisions locked at scoping time:
> - **The line is gain/loss, not raw value.** Value is the hero number above the
>   chart; the plot is cumulative gain.
> - **Deposits and withdrawals are flagged and excluded from gain.** Moving money
>   in is never performance.
> - **History is backfilled from `get_realized_pnl`** so the chart is useful on
>   first run, with the seam labeled.
> - **One series at a time.** Combined total by default; a chip swaps the chart to
>   that account.
> - **We record our own time series.** There is no portfolio-value history API.

**Status 07-27 — SHIPPED, all phases** (archived 07-28 as
`07-27-26-portfolio-history-roadmap.md`; originally
`PORTFOLIO_HISTORY_ROADMAP.md`, the name ~14 code comments still cite).
Phases 0–6 landed in one arc, each probed against the live API before commit.
What the plan did not predict:

- **The sanity gate was suppressing its own evidence.** Phase 0's
  order-of-magnitude check rejected a $500 deposit into a $3.38 account (149×) —
  throwing away the day AND the transfer prompt that would have explained it. It
  now requires a fold violation *and* real money moved.
- **The chart's seam was drawn as a break.** Running the real 32-point series
  through the geometry showed the 1M view drawing no line at all: a *gap* and a
  *change of measure* had been treated as the same event. 25 chart tests were
  green while it was broken.
- **A new account's opening balance counted as gain** ($910 of "performance" for
  opening an account) — found by a Phase 6 command test, fixed by folding
  entering accounts in with the hand-marked flows.
- **Ranges meant nothing until they were rebased**, and rebasing to the previous
  point credited sixteen months of recovery to "past month" — so windows re-zero
  at their first *visible* point.
- **Added after the plan, on operator request:** transfer marks on the chart
  (a netted-out deposit is otherwise invisible and its arithmetic uncheckable),
  and per-account exclusion from the combined total, disclosed everywhere it
  applies.

Superseded by TRADING_TAB_ROADMAP, which moved this chart onto the top-level
Trading tab and built the dashboard around it.

---

## Outcome

Open the Trading tab and see what the money has actually done: today's total as a
hero number, a line of cumulative gain/loss beneath it, and a range control that
walks from a week out to everything we know. Every point is either a real reading
we took or a real number Robinhood gave us — never an interpolation, never a
reconstruction, and never a deposit wearing a gain's clothes.

## How far we take it — and where we stop

**We are building:** a local daily ledger of account balances, a manual
deposit/withdrawal register, a realized-P&L backfill, one honest chart with a
time-range control and a hover readout, and read access to the series from the
command surface.

**We are not building:** benchmark comparison (vs SPY), time-weighted or
money-weighted return math, tax-lot accounting, per-symbol attribution,
projections or forecasts, intraday granularity, or a second charting surface
elsewhere in the app. Each of those is a real product; none is this one.

---

## Three constraints that shape everything

**1. Robinhood has no portfolio-value history. We must become the recorder.**

Probed the full 50-tool surface on 07-27. What exists: `get_portfolio` (current
value only), `get_equity_historicals` (per-symbol OHLCV), `get_pnl_trade_history`
(individual closed trades), `get_realized_pnl` (bucketed realized gain). What does
not exist: any endpoint returning what the account was worth on a past date.

So the daily series is ours to keep. Nothing recovers a day we failed to record —
which makes the recording path (Phase 0–1) load-bearing in a way the chart is not.

**2. There is no transfers/ACH tool, so flows cannot be detected automatically.**

Nothing in the MCP surface reports a deposit. We can see cash change, but a cash
increase is equally explainable by a deposit, a sale, or a dividend. Inferring it
would be guessing about the user's money, so we don't: **flows are entered by
hand** (or by the agent, on the user's instruction) and stored in their own table.
An unflagged deposit shows up as gain — and the roadmap's answer to that is a
visible, dismissable prompt when a day's change is anomalous, not silent
correction.

**3. Every number originates from a language model reading a tool result.**

Stage 1 already routes balances through haiku. That pipeline is measured at
roughly 1 failure in 6 (07-27, six live runs) and returns floats, occasionally
with unmasked account numbers. A ledger is less forgiving than a panel: a bad
number persists and deforms the chart forever. Phase 0 therefore adds a sanity
gate before any row is written, and stores integer cents — never floats.

---

## One place this differs from the chosen option, and why

The backfill choice was presented as *dashed before today, solid after, one axis*.
Built literally, that puts two different measures on one y-scale — realized P&L is
a **flow** (gain per period), account value is a **level** (total worth). $41 of
realized P&L and $915 of account value share a dollar sign and nothing else;
plotting them against one axis is the dual-axis anti-pattern with the second axis
hidden.

**The fix keeps the single axis and changes what the line measures.** Plot
**cumulative gain/loss**, not value:

- **Before recording started:** cumulative realized P&L from Robinhood (dashed).
- **After recording started:** that same running total, continued by
  `(Δvalue − flows)` each day (solid).
- **Account value** becomes the hero number above the plot, where a level belongs.

Now both segments are the same unit *and* the same measure — dollars gained or
lost, accumulating. The seam is no longer a change of meaning, only a change of
**completeness**: before the seam we can only see gains you *realized* by selling;
after it we also see gains you're still holding. That is one sentence to label,
and it sits under the chart.

```
CUMULATIVE GAIN / LOSS                    TOTAL VALUE  $915.88
                                                today  +$12.40 ▲

  +$60 ┤                                        ╭──────
       │                              ╭─────────╯
  +$30 ┤              ╭╌╌╌╌╌╌╌╌╌╌╌╌╌╌╯
       │      ╭╌╌╌╌╌╌╯               ┊
    $0 ┼╌╌╌╌╌╯                       ┊
       └──────────────────────────────────────────────
        Feb        Apr        Jun    ┊  Jul
                                     └ recording began 07-27

  ╌╌╌ realized trades only (Robinhood)   ─── realized + unrealized (recorded here)
```

**If you'd rather not have a seam at all**, the alternative is two stacked panels
sharing one x-axis and one range control — value on top, realized P&L below. It's
more honest-by-construction and costs a second plot. Say so before Phase 4 and
I'll build that instead.

---

## Data model

Three tables. Money is **integer cents** everywhere; dates are **market days in
America/New_York**, matching
`get_realized_pnl`'s default bucket boundary.

```
portfolio_snapshots                    one balance reading per account per day
  account_key   string   last4 — the same key stage 2 already matches on
  label         string   denormalized so renamed accounts don't rewrite history
  captured_on   date
  value_cents   integer
  cash_cents    integer
  buying_power_cents integer
  source        string   "tab_open" | "daily_pump" | "manual"
  unique (account_key, captured_on)    later readings that day overwrite

portfolio_flows                        deposits and withdrawals, entered by hand
  account_key   string
  occurred_on   date
  amount_cents  integer  positive = deposit, negative = withdrawal
  note          string
  source        string   "manual" | "agent"

realized_pnl_points                    the backfill, from Robinhood
  account_key   string
  bucket_on     date
  realized_cents integer
  closing_trades integer
  unique (account_key, bucket_on)
```

**The combined total is derived, never stored** — and derived under one rule that
matters more than it looks:

> A total point exists for a day **only if every known account has a reading that
> day.** A partial total is a fake crash: three accounts recorded and one missed
> renders as a cliff exactly the size of the missing account.

Same rule, restated for the chart: a day with an incomplete total is a **gap**, and
gaps are drawn as gaps.

---

## Phases

### Phase 0 — The ledger

The recording path, with no chart in sight.

- Migration for `portfolio_snapshots`; `BusterClaw.Portfolio` context.
- `record_snapshot/1` upserts one row per account per market day from a stage-1
  result. Idempotent: opening the tab six times in a day leaves one row.
- **Float→cents conversion in one place**, rounded once, with the raw float never
  reaching the DB.
- **Sanity gate before write.** Reject a reading that is negative, non-numeric, or
  more than an order of magnitude from the previous reading for that account; log
  and skip rather than persist. A rejected day is a gap, which is recoverable — a
  poisoned row is not.
- Wire into `handle_async(:trading_account, …)` so every stage-1 fetch records.

**Done when:** opening the tab twice in one day yields exactly one row per
account; a restart preserves them; a hand-crafted absurd value is refused; `mix
precommit` green.

### Phase 1 — Recording without gaps

Opening the tab is not a schedule. A supervised daily pump makes the series
continuous.

- `BusterClaw.Portfolio.Recorder` — a GenServer on the `Notifications.Scheduler` /
  `WalletPoller` pattern: config-gated in `application.ex`, **off in tests**,
  crash-safe, arms a timer rather than polling hot.
- Fires once per market day after close (US Eastern), runs stage 1, records.
- **Market-day aware.** Weekends and holidays get no reading at all rather than a
  duplicate — a flat weekend implies two days of zero movement, which is a claim
  we shouldn't make.
- Respects the same failure posture as the panel: a failed run logs and retries
  tomorrow; it never writes a placeholder.

**Done when:** a day the app was never opened still has a reading; a weekend has
none; killing the pump mid-run leaves no partial row.

### Phase 2 — Flows, and the gain math

- Migration + schema for `portfolio_flows`.
- `gain_for(account, day) = (value[d] − value[d−1]) − Σ flows[d]`, with
  `cumulative_gain` folding forward from the first recorded day.
- UI to mark a day: amount, deposit/withdrawal, optional note.
- **Anomaly prompt.** When a day's raw change exceeds a threshold, the panel asks
  whether it was a transfer — visible, dismissable, never auto-applied. This is
  the mitigation for constraint 2, and it must not become silent inference.
- Flows are per-account; the total's flows are the sum.

**Done when:** marking a $500 deposit leaves the value line stepping up while the
gain line does not move; unmarking restores it; a withdrawal works symmetrically.

### Phase 3 — Backfill

- Stage-3 prompt on the `detail_prompt/1` pattern: `get_realized_pnl` with
  `span: "all"` for one account, identified by last four, read-only.
- Parse to `realized_pnl_points`; run once per account, on demand, not on a timer.
- Bucket granularity from `span: all` is likely coarser than daily — **store what
  it gives and let the chart's resolution visibly improve at the seam** rather than
  faking daily points.
- Cumulative-gain series joins the two segments continuously at the seam date.

**Done when:** a fresh install shows real history on first open; the seam date is
labeled; deleting the backfill degrades to Phase 2 behavior without error.

### Phase 4 — The chart

Server-rendered SVG in the LiveView — no charting dependency, nothing external
(the CSP forbids it), data already server-side.

- Hero number (total value + today's change) above a single-series line.
- Range control in one row above the plot: **1W · 1M · 3M · 1Y · ALL**.
- **Downsample by range**, daily → weekly → monthly, so a 5-year view isn't 1,800
  marks in 400px. Label the active granularity.
- Gaps render as gaps. **No interpolation across missing days, ever.**
- Zero baseline is drawn and labeled, since the series crosses it.
- Marks per house spec: 2px line, ≥8px hover markers, recessive grid.
- Colors: gain/loss uses the existing `--color-success` / `--color-error` tokens,
  already CVD-validated for both themes (ΔE 9.7 dark / 7.4 light) by the buy/sell
  chips. **Sign is also written, never carried by color alone.** One series means
  no categorical palette and no legend — a consequence worth keeping.

**Done when:** it renders correctly with 0, 1, 2, and 400 points; with a gap in the
middle; with an all-negative series; in both themes; and the range control changes
granularity visibly.

### Phase 5 — Reading it

- Crosshair + tooltip via a small JS hook reading data attributes off the SVG
  (date, value, day change, cumulative, flow marker if any).
- Keyboard: arrow keys walk points, so the chart isn't mouse-only.
- **Table view** behind a toggle — the accessible equivalent and the thing you
  copy numbers out of.
- Empty state states plainly when recording began.

**Done when:** hover and keyboard produce the same readout; the table matches the
plot exactly; a screen reader reaches every value.

### Phase 6 — The agent can read it

- `portfolio_history` (safe tier) — series by range and account.
- `portfolio_flow_list` (safe) / `portfolio_flow_add` (restricted, mutating).
- Catalog entries under `Commands.Catalog.Finance`.

**Done when:** `./buster-claw run portfolio_history --json '{"range":"1M"}'` returns
the same numbers the chart draws.

---

## Honesty rules (these are the acceptance criteria that matter)

1. **Never interpolate a missing day.** A gap is information.
2. **Never render a partial total.** Incomplete day → gap, not a cliff.
3. **Never infer a transfer.** Ask; don't assume.
4. **Never store a float.** Cents in, cents out, rounded once.
5. **Never let the pre-seam and post-seam segments look identical.** They measure
   different completeness and must be visually and textually distinct.
6. **Never auto-poll harder than daily.** Each reading is a real agent run against
   a flaky remote; a tight loop burns tokens and adds no resolution.

## Risks

| Risk | Mitigation |
|---|---|
| Stage 1's ~1-in-6 failure rate leaves holes | Pump retries next day; gaps drawn honestly; sanity gate blocks bad rows |
| A wrong model number persists into history | Order-of-magnitude gate at write; manual correction path via the flows/manual source |
| Unflagged deposits inflate gain | Anomaly prompt at Phase 2; flows visible on the chart |
| `get_realized_pnl` buckets too coarse to be useful | Backfill is one phase and independently removable; chart degrades to Phase 2 |
| Account `last4` collides across accounts | Already handled in `Trading.uniquify/1`; ledger keys on last4 + label — revisit if a real collision appears |

## Open questions

- **Retention.** Daily rows are tiny (365/account/year), so no pruning is planned.
  Flag if you want a cap.
- **Crypto accounts.** They report balances but no holdings; their *value* still
  charts fine. Untested against real data — no crypto account has appeared in
  `get_accounts` on any probe.
- **The seam design.** Single-axis cumulative gain (above) vs two stacked panels.
  Decide before Phase 4.
