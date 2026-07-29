# Trading Tab — Critical Review and Remediation Roadmap

**Date:** 2026-07-27 · **Status:** ACTIVE BUILD-OUT · **Recommendation:** Do not ship with real-money write access until Stages 0–2 are complete.

> **Verdict:** The Trading tab contains unusually thoughtful financial-display
> work, but its execution boundary is unsafe and several correctness defects can
> display or permanently persist the wrong financial data. The warning banner is
> not a control, a system prompt is not an authorization boundary, and the
> current account identity scheme is not safe enough for a ledger.

---

## The short version

The tab is trying to be two products at once:

1. A read-only portfolio dashboard with balances, positions, cost basis,
   performance history, symbol charts, earnings, and recent activity.
2. A free-form natural-language order terminal connected directly to Robinhood.

The first product has good instincts: raw account numbers are masked, money is
persisted in integer cents, stale data carries as-of labels, missing information
is often kept distinct from zero, gaps remain gaps, and the last good snapshot
survives a failed refresh.

The second product is not safe enough to ship. A user message goes directly to a
headless Claude session running with permission prompts bypassed. The application
does not own an order-intent state machine, preview, confirmation, limit, or
complete audit record. Several data paths also use a language model as the
transcription layer between brokerage tools and the permanent ledger.

The immediate direction should be:

- Make the tab read-only until a deterministic order gate exists.
- Replace last-four account identity with a stable opaque identifier.
- Remove the model from financial data ingestion.
- Fix the chart DOM and asynchronous navigation races.
- Add browser-level and execution-boundary tests before expanding the feature.

---

## Critical findings

### 1. There is no hard safety boundary around real orders

The chat system prompt permits placing, amending, and cancelling orders on the
Agentic account (`lib/buster_claw/trading.ex:85-108`). That prompt is appended to
a Claude process launched with:

```text
--permission-mode bypassPermissions
```

See `lib/buster_claw/agent_runner.ex:165-166`.

At the application layer there is no:

- Structured order intent
- Deterministic account/symbol/side/quantity validation
- Order preview
- Explicit user confirmation
- Maximum notional or quantity
- Symbol allowlist or denylist
- Idempotency key
- Market-hours or order-type policy
- Reconciliation record containing the submitted arguments and broker result

The banner saying that real orders execute on the Agentic account is disclosure,
not protection. The Stop button can kill the local agent process, but it cannot
roll back an order already accepted remotely.

This is also inconsistent with the product's own stated security philosophy.
`lib/buster_claw/introduction.ex:552-557` says that actions leaving the machine
and irreversible actions require confirmation. A real-money market order is at
least as consequential as the gated email and deletion actions described there.

#### The audit trail is insufficient

`TradingLive.dispatch_chat/2` records the outbound message's character count,
not its order intent (`lib/buster_claw_web/live/trading_live.ex:307-323`).
Completed chat runs record duration, turns, cost, session, and outcome, but not
the Robinhood tool arguments (`lib/buster_claw/agent/chat.ex:519-548`).

For non-Bash tools, the persisted transcript summary is only the tool name
(`lib/buster_claw/agent/stream_event.ex:138-139`). It therefore cannot reliably
answer:

- Which account was targeted?
- Which symbol, side, quantity, price, and order type were submitted?
- What broker order identifier came back?
- Was the order accepted, rejected, partially filled, cancelled, or duplicated?

**Severity:** Critical  
**Ship blocker:** Yes

---

### 2. Last-four account identity can misattribute and overwrite financial data

The code explicitly handles two accounts sharing their last four digits by
suffixing the second account's display ID
(`lib/buster_claw/trading.ex:835-850`).

However, the stage-two holdings and orders prompt identifies the account only by
last four and says:

> If more than one does, use the first.

See `lib/buster_claw/trading.ex:124-148`.

This means selecting the second colliding account can fetch the first account's
positions and orders, then merge those results into the second account's UI
record.

The collision propagates beyond the account panel:

- Portfolio snapshots key on last four (`lib/buster_claw/portfolio.ex:141-149`).
- The database permits one snapshot per `account_key` and day
  (`priv/repo/migrations/20260727210000_create_portfolio_snapshots.exs:35-38`).
- Transfers, exclusions, realized-P&L backfill, and cost-basis records also use
  the shortened identity.

Two accounts sharing the same digits can therefore overwrite daily readings,
share exclusions, merge transfers, or display the wrong holdings and activity.

Privacy does not require weak identity. Store a stable opaque broker identifier,
or a keyed hash/HMAC of the full identifier, while continuing to expose only a
masked label to the UI.

**Severity:** Critical  
**Ship blocker:** Yes

---

### 3. A language model is being used as financial ETL

The architecture deliberately routes brokerage data through the operator's
Claude CLI. The module documentation acknowledges that every number transits a
language model (`lib/buster_claw/trading.ex:28-31`), and read jobs use Haiku
before parsing its text output (`lib/buster_claw/trading.ex:728-740`).

That transcription supplies:

- Account balances and buying power
- Holdings and order activity
- Cost basis and tax-lot totals
- Quotes and index values
- OHLCV bars
- Earnings dates
- Realized P&L
- Permanent portfolio history

The parsers catch malformed JSON and some impossible shapes. They cannot detect
a plausible transcription error. A balance that is wrong by 5%, 20%, or several
thousand dollars may remain structurally valid.

The permanent-ledger guard only rejects a movement when it is both at least
$5,000 and more than 50-fold (`lib/buster_claw/portfolio.ex:65-78` and
`lib/buster_claw/portfolio.ex:174-193`). That is a garbage filter, not source
verification.

The model can still be useful for narration, research, and explaining structured
results. It should not be the component copying brokerage numbers into the
source-of-truth ledger.

**Severity:** Critical  
**Ship blocker:** Yes for durable financial truth

---

## High-severity implementation defects

### 4. The chart can retain an old SVG after the account or range changes

The portfolio chart wraps its server-rendered SVG in:

```heex
phx-hook="PortfolioChart"
phx-update="ignore"
```

See `lib/buster_claw_web/components/portfolio_chart.ex:152-158`.

With `phx-update="ignore"`, LiveView can update the wrapper's attributes but does
not patch its SVG children. The JavaScript hook's `updated()` callback rereads
the new tooltip/readout JSON and clears the cursor, but it never redraws the
path, dots, axes, or SVG accessibility label
(`assets/js/hooks/portfolio_chart.js:40-45`).

The result can be an updated headline and tooltip dataset over an old line. The
same problem affects symbol range changes when the plot's DOM ID remains stable.
This is particularly dangerous because the chart looks valid rather than
obviously broken.

**Severity:** High

---

### 5. Rapid account switching can leave holdings loading forever

Selecting an account calls `maybe_load_detail/1`
(`lib/buster_claw_web/live/trading_live.ex:258-264`). If another account is
already loading, the new selection is accepted but its fetch is suppressed
(`lib/buster_claw_web/live/trading_live.ex:783-784`).

When the old request lands, its result is stored and the global loading state is
cleared, but the newly selected account is not retried
(`lib/buster_claw_web/live/trading_live.ex:485-488` and
`lib/buster_claw_web/live/trading_live.ex:810-822`).

The new account can then display `Loading holdings…` with no task in flight.
Symbol-bar fetching has the same class of shared-boolean race when the user
changes symbols or ranges during a fetch.

Async work should be keyed by the requested resource, and completion should
either reconcile against the current selection or trigger the current
selection's missing fetch.

**Severity:** High

---

### 6. The latency and freshness model is not suitable for interactive trading

Configured timeouts reveal the actual interaction budget:

- Account snapshot: 180 seconds
- Account detail: 180 seconds
- Cost basis: 240 seconds
- Symbol bars: 300 seconds
- Market-data sweep: 480 seconds

See `lib/buster_claw/trading.ex:220-244`.

The normal market-data sweep runs once per trading day after 4:30 p.m. Eastern
(`lib/buster_claw/portfolio/recorder.ex:21-33` and `:44-45`). The quotes cache
calls itself stale after 15 minutes, but its normal refresh cadence is daily.

The UI usually discloses age, which is good, but it still makes definitive claims
when data is absent. `MarketData.upcoming_earnings/1` returns an empty list both
when there are no reports and when the cache is missing or unreadable
(`lib/buster_claw/market_data.ex:300-316`). The UI converts both states into:

> No earnings scheduled for your holdings in the next month.

See `lib/buster_claw_web/live/trading_live.ex:1290-1296`.

Unknown, stale, failed, and confirmed-empty must remain distinct throughout the
view model.

**Severity:** High

---

## Product and UX findings

### 7. Onboarding state is inferred from chat history, not connection state

The one-time Robinhood setup block appears when `@chat_seq == 0`
(`lib/buster_claw_web/live/trading_live.ex:857-870`).

Consequences:

- An authenticated user with an empty transcript sees setup indefinitely.
- A logged-out user with an old transcript does not see setup.
- OAuth health is discovered only after a failed agent run.

The tab needs a real connection state with Connect, Reconnect, Verify, and
Disconnect actions.

### 8. Claude detection and Trading compatibility disagree

Mount treats any detected agent CLI as sufficient
(`lib/buster_claw_web/live/trading_live.ex:47`). Dispatch later requires Claude
specifically and rejects Codex (`lib/buster_claw_web/live/trading_live.ex:310-326`).

A machine with Codex but not Claude gets an enabled composer and then a runtime
error. Compatibility should be determined before rendering the active control.

### 9. The shared chat UI is contextually wrong

The Trading tab reuses a chat component whose empty state tells users to check
mail, work the queue, or look something up
(`lib/buster_claw_web/components/chat_panel.ex:125-130`). The composer says only
“Message Buster Claw.”

Inside a real-money surface, the empty state should explain:

- Whether the surface is currently read-only or trade-enabled
- What the agent can inspect
- What constitutes an order request
- What will require confirmation
- How stale the dashboard may be
- Where completed order records can be reviewed

### 10. The dashboard has no dominant user workflow

The right panel contains, in one scrolling surface:

- Total value and day change
- Market indexes
- Account selector
- Transfer anomaly correction
- Portfolio performance chart
- Symbol charts and candles
- Consolidated positions
- Cost-basis loading
- Upcoming earnings
- Account list and exclusions
- Per-account allocation
- Recent order activity
- Refresh state

The implementation has considered many individual empty states, but the product
has not chosen a primary job. Monitoring, performance analysis, account
administration, market research, transfer reconciliation, and order execution
all compete for attention.

A safer, clearer hierarchy would separate:

1. Portfolio overview
2. Position/symbol research
3. Account history and reconciliation
4. Explicit order workflow

### 11. “Recent activity” conflates orders with trades

The detail prompt fetches equity orders, but the UI repeatedly describes them as
trades and says “No trades yet.” An order can be queued, rejected, cancelled,
partially filled, or filled. It is not synonymous with a trade.

The parser also accepts arbitrary position and order maps without normalizing
symbols, quantities, sides, prices, states, or timestamps
(`lib/buster_claw/trading.ex:853-874`).

Order history should preserve the broker order identifier, order type, submitted
quantity, filled quantity, average fill price, state transitions, and timestamps.

---

## Maintainability review

The feature slice is large and tightly concentrated:

| File | Lines |
|---|---:|
| `lib/buster_claw_web/live/trading_live.ex` | 1,728 |
| `lib/buster_claw/trading.ex` | 949 |
| `lib/buster_claw/portfolio.ex` | 987 |
| `lib/buster_claw/market_data.ex` | 436 |
| `lib/buster_claw_web/components/portfolio_chart.ex` | 1,049 |
| `assets/js/hooks/portfolio_chart.js` | 145 |

`TradingLive` owns chat orchestration, account fetching, portfolio recording,
transfer correction, chart selection, cost-basis refreshes, symbol-bar fetches,
market context, error presentation, and the entire dashboard template. Global
assigns such as `trading_detail` and `symbol_bars_loading` are already producing
cross-resource races.

Suggested boundaries:

- `TradingChatLive` or a trading-specific chat component
- `PortfolioOverview`
- `AccountDetail`
- `PositionTable`
- `OrderActivity`
- `TransferReconciliation`
- A dedicated fetch/coordinator process keyed by resource
- A deterministic order-intent context separate from chat

---

## Test assessment

The focused suites reviewed during this audit pass:

```text
mix test test/buster_claw/trading_test.exs \
  test/buster_claw_web/live/trading_live_test.exs

78 tests, 0 failures

mix test test/buster_claw_web/components/portfolio_chart_test.exs

53 tests, 0 failures
```

The test volume is good, but the confidence is concentrated at the wrong layer.
Current coverage heavily validates:

- Prompt text
- JSON parsing
- Pure financial calculations
- SVG geometry
- Server-rendered HTML
- Cached and failed fetch states

The reviewed suites do not cover:

- A real `chat_send` order path
- Application-level order authorization
- Preview and confirmation, because neither exists
- Complete order audit records
- Account identity collisions across detail and ledger storage
- LiveView browser DOM patching with `phx-update="ignore"`
- Rapid account switching during an in-flight fetch
- Rapid symbol/range switching during an in-flight fetch
- Stop-after-tool-dispatch behavior

The test run also excluded `:browser_engine`, so pure rendering tests cannot catch
the stale SVG defect.

---

## Remediation roadmap

### Build progress — 2026-07-27

The first safety/correctness slice is implemented:

- Trading chat and background reads now run Claude in `dontAsk` mode with built-in
  tools disabled and an explicit allowlist containing only Robinhood `get_*`
  tools.
- The system prompt, banner, account badges, and operator introduction now state
  that order writes are disabled on every account.
- Duplicate last-four account identities fail closed: balances remain visible,
  while detail, ledger, cost, backfill, flow, and exclusion actions are disabled.
- Portfolio and symbol charts no longer freeze their server-rendered SVG behind
  `phx-update="ignore"`.
- Account-detail and symbol-bar requests hand off to the current selection after
  an older in-flight request completes.
- Transfer amounts reject trailing junk instead of accepting a numeric prefix.
- Position and order rows are normalized before display; malformed financial rows
  are dropped.
- Earnings now distinguish unavailable data from a confirmed empty calendar.
- Trading uses context-specific read-only chat copy and correctly requires Claude,
  not merely any agent CLI.
- LiveView events now authorize account IDs, exclusion keys, portfolio ranges,
  symbols, symbol ranges, symbol modes, and transfer identity against server
  state before changing financial UI or persistence.
- A selected account that disappears during refresh now returns to the explicit
  combined view rather than silently substituting another account.
- Symbol-bar loading carries the exact symbol, interval, and requested range, so
  an obsolete completion cannot clear a different request's loading state.
- The Trading banner documents that Stop interrupts the local run only and
  cannot reverse a broker action performed elsewhere.
- `BusterClaw.DataState` now carries `loading | fresh | stale | unavailable |
  confirmed_empty`, the governing timestamp, source, reason, and payload.
- Account balances, portfolio performance, indexes, holdings/cost basis, each
  symbol price, symbol history, earnings, order history, and the manual-transfer
  ledger now render through explicit dataset states.
- Successful empty positions responses now persist refresh evidence, so an empty
  brokerage response survives remounts as `confirmed_empty` instead of reverting
  to “not loaded.”
- Price freshness is evaluated per symbol (quote versus daily-close fallback);
  the section reports the worst row state and each displayed price names its own
  source and timestamp.
- The product is explicitly labeled an end-of-day portfolio monitor. Live order
  execution remains disabled, so no daily close is presented as an execution
  quote.
- Activity now separates non-filled orders, filled-order status, manual transfer
  reconciliations, unavailable dividend data, and market movement.
- Focused runner/chat/trading/market-data/LiveView regressions pass.

### Direct broker progress — 2026-07-28

- A first-party Robinhood Trading MCP connection now performs protected-resource
  and authorization-server discovery, dynamic public-client registration, OAuth
  authorization-code exchange with PKCE, refresh-token rotation, and strict
  endpoint validation.
- Access tokens, refresh tokens, and broker account identifiers are encrypted at
  rest. Durable broker account relationships use a namespaced HMAC key instead
  of an account number or last four.
- The direct Streamable HTTP MCP client negotiates a pinned protocol version,
  maintains server sessions, accepts structured JSON or SSE results, paginates
  tool discovery, and rejects every tool outside an explicit read/review
  allowlist before a network call.
- Trading now exposes real connection health and Agentic-account discovery in
  the deterministic order lane. The OAuth callback verifies signed, short-lived
  state and keeps the PKCE verifier encrypted.
- `review_equity_order` is required during health checks, but production review
  mapping now uses Robinhood's live-advertised schema together with structured
  portfolio and position reads. It derives current quote freshness, authoritative
  buying power, estimated notional, and post-trade concentration without model
  transcription.
- The Trading lane can render live review facts, the broker's verbatim market-data
  disclosure, and open-ended order alerts. Confirmation and submission controls
  remain absent because order placement is still unreachable.

### Stage 0 — Stop expanding the unsafe surface

- [x] Make Robinhood MCP access read-only from the Trading chat.
- [x] Remove or disable order-writing tools until an application-owned gate exists.
- [x] Change the banner to state the current enforcement mode, not merely describe
      Robinhood account capabilities.
- [x] Document that Stop cannot reverse an accepted remote action.

**Done when:** No free-form model turn can place, amend, or cancel an order.

### Stage 1 — Establish trustworthy identity and data lineage

- [x] Introduce a stable opaque account key or HMAC-based identity for the new
      direct broker boundary.
- [ ] Migrate snapshots, flows, exclusions, realized P&L, and cost basis away from
      last-four keys.
- [x] Detect collisions and refuse ambiguous association. Migration to a stable
      opaque key remains outstanding.
- [ ] Replace model-transcribed brokerage reads with structured machine-to-machine
      responses.
- [ ] Retain the model only for explanation and research over already validated data.
- [ ] Add provenance fields to durable records: source request, broker timestamp,
      fetched timestamp, and response identifier where available.

**Done when:** Two accounts can never share a persistence identity, and no model
text is parsed into the permanent financial ledger.

### Stage 2 — Build a deterministic order workflow

- [x] Parse explicit `/order` chat requests into a non-executable draft order.
- [x] Resolve account, symbol, side, quantity/notional, order type, limit price, and
      time-in-force in deterministic code.
- [x] Fetch a current quote and buying power immediately before preview through
      direct structured Robinhood MCP calls, then bind them to the expiring
      preview digest.
- [x] Apply configurable notional, concentration, symbol, and market-hours rules.
- [x] Show a structured order preview separate from the transcript.
- [x] Require explicit confirmation tied to the exact preview payload, including
      the broker review and warnings.
- [x] Attach an idempotency key and expire stale confirmations.
- [ ] Submit through an application-controlled broker adapter.
      The adapter behaviour, fail-closed default, and tested submission boundary
      exist; a production Robinhood MCP implementation is still required.
- [x] Persist the exact request, confirmation digest, broker identifier, response,
      and subsequent status transitions in an append-only event trail.
- [x] Reconcile accepted and unknown-outcome orders until terminal state through
      a supervised, bounded recovery loop keyed by the durable client order id.

**Done when:** The model can propose an order but cannot execute one; only a
validated, confirmed, audited application transaction can do so.

### Stage 3 — Repair browser correctness and async state

- [x] Remove inappropriate `phx-update="ignore"` usage or make the hook fully own
      and redraw the SVG DOM.
- [x] Rebind all hook element references after patches.
- [x] Key account-detail loading state by account.
- [x] Key symbol-bar loading state by symbol, interval, and range.
- [x] Hand off from obsolete fetches to the current selection. Fully parallel keyed
      fetches remain a later optimization.
- [x] On completion, reconcile against the current selection and launch any still
      missing current request.
- [x] Validate all LiveView event values, including portfolio ranges and symbols.
- [x] Reject partially parsed transfer amounts such as `500abc`.

**Done when:** Rapidly switching accounts, symbols, modes, and ranges cannot
display stale data or leave a phantom loading state.

### Stage 4 — Make freshness and uncertainty explicit

- [x] Introduce `loading | fresh | stale | unavailable | confirmed_empty` states for
      every dashboard dataset.
- [x] Stop translating earnings-cache failure into definitive empty-state copy.
      Apply the same state model to the remaining datasets.
- [x] Display data timestamps beside the values they govern.
- [x] Define whether the product is end-of-day portfolio monitoring or live trading.
- [x] Resolve the live-quote requirement: the current product is explicitly
      end-of-day and order writes are disabled. Any future executable-order stage
      must add an appropriately current quote path before preview.
- [x] Separate orders, fills, transfers, dividends, and market movement in activity.

**Done when:** The UI never claims “none,” “zero,” or “current” when the real state
is unknown, missing, or stale.

### Stage 5 — Simplify the product surface

- [ ] Replace transcript-based setup detection with real Robinhood connection health.
- [x] Give the Trading tab context-specific onboarding and composer copy.
- [ ] Split portfolio monitoring from order execution.
- [ ] Establish one primary dashboard question per view.
- [ ] Move transfer reconciliation and account exclusions into secondary workflows.
- [ ] Break the 1,728-line LiveView into resource-focused components and contexts.

**Done when:** A user can identify the tab's primary purpose in five seconds and
cannot confuse read-only portfolio data with an executable order surface.

### Stage 6 — Add the missing confidence tests

- [ ] Browser test: account and range changes redraw the actual SVG path.
- [ ] Browser test: tooltip, accessibility label, headline, and plotted line agree.
- [x] LiveView test: switch accounts while the first detail fetch is in flight.
- [x] LiveView test: switch symbols/ranges while a bar fetch is in flight.
- [x] Persistence test: two accounts with identical last four fail closed rather
      than sharing a ledger identity.
- [x] Security test: an unconfirmed order can never reach a write tool.
- [x] Security test: a confirmed payload cannot be altered or replayed.
- [x] Audit test: every submitted order can be reconstructed from durable records.
- [x] Recovery test: an accepted or unknown-outcome order still reconciles to a
      terminal broker state through the supervised recovery pump.

**Done when:** The dangerous paths are tested through the same browser, process,
and persistence boundaries used in production.

### Stage 7 — Deferred shader-based financial visualization

Do not begin this stage until the correctness work above is stable. Shader work
should make relationships easier to perceive; it must never become another
source of financial calculations or hide uncertainty behind visual spectacle.

- [ ] Prototype shader-driven portfolio movement, allocation, volume, or risk
      views using the already validated server-side data model.
- [ ] Keep all financial calculations in deterministic Elixir code; shaders
      receive display-ready values only.
- [ ] Preserve the existing SVG/table representation as an accessible fallback
      and copy/export surface.
- [ ] Respect reduced-motion preferences and provide a static mode.
- [ ] Cap GPU work when the tab is hidden, the window is backgrounded, or the
      visualization is outside the viewport.
- [ ] Test color contrast and provide text/shape encodings so gain/loss,
      buy/sell, and uncertainty are never communicated by color alone.
- [ ] Compare comprehension against the conventional chart before promoting a
      shader prototype into the main workflow.

**Done when:** The shader view materially improves comprehension, remains
optional, and cannot disagree with the conventional chart or accessible table.

---

## What should be preserved

The remediation should retain the strongest parts of the current implementation:

- Raw account numbers are masked app-side even when the model returns them.
- Financial persistence uses integer cents.
- Missing cost basis is not rendered as zero.
- Last-good snapshots remain visible after failed refreshes.
- Portfolio chart gaps are not connected with invented lines.
- Transfer corrections are disclosed in performance history.
- Data timestamps are available and often shown.
- Parsing generally drops malformed rows instead of inventing replacements.
- The existing pure financial and geometry tests provide a useful foundation.

Those choices show the right instincts. The roadmap is not asking for a rewrite
of the financial UI; it is asking for the execution, identity, data-lineage, and
browser-state foundations to meet the same standard.

---

## Final recommendation

Treat the existing Trading tab as a strong prototype for read-only portfolio
monitoring, not as a production-safe order terminal.

The correct launch sequence is:

```text
read-only portfolio
  → trustworthy account identity
  → direct structured financial data
  → deterministic order drafts
  → explicit confirmation
  → audited broker submission
  → reconciliation
```

Do not invert that sequence by letting a free-form model execute trades while the
application catches up on controls afterward.
