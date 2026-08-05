# Market watchlist — choosing which symbols the cache holds

**Scoped 08-04-26 · Status: SCOPED, nothing built.**

The Chart Build agent told the operator it could not chart NVDA or SPY, could not
add them, and could not say why — only infer from what the cache contained. It
was right to refuse and right about most of its inference. This roadmap gives the
operator a way to say *which symbols matter*, and gives Chart Build a reason to
treat some symbols as chartable over a year and others as chartable over a week.

**The operator's ask (08-04):** a watchlist users can add tickers to; those
tickers support **advanced charts** (deep history), and any other ticker supports
**short-term charts** only.

---

## Measured first (08-04, the dev database and the code)

Everything here is read from `buster_claw_dev.db` or from the call path, not
inferred from behaviour.

**The cache holds three symbols and no benchmarks:**

| symbol | bars | first | last |
|---|---|---|---|
| GOOGL | 65 | 2026-04-30 | 2026-08-03 |
| QXO | 65 | 2026-04-30 | 2026-08-03 |
| HOOD | 6 | 2026-07-27 | 2026-08-03 |

**Symbols are discovered from HOLDINGS, and only holdings.**
`MarketData.refresh/1` → `Trading.fetch_market_data/1`, whose prompt opens
*"Collect market data for the operator's holdings"*. There is no other route in
for the daily sweep. So the agent's guess — "make the app track them" — was
right in spirit, and the mechanism is narrower than it guessed: **a symbol enters
the cache by being held, full stop.** HOOD's 6 bars are a symbol that became held
recently; nothing about watchlists is involved, because nothing about watchlists
exists.

**Benchmarks are a separate, hardcoded path with no rows yet — and the reason is
NOT that it is broken.** `@benchmark_symbols ~w(SPY QQQ DIA IWM)`, target 240
bars, 370 calendar days back, via `backfill_benchmark/2` on the chart tier. The
cache has zero rows for all four.

**Corrected 08-04 after measuring** (this file's first draft said the backfill
"runs and yields nothing" and called that failure durable — a conclusion drawn
from a single attempt):

- The feature landed **2026-08-03 21:07**, after that day's fire time. Today is
  the 4th. So **exactly one backfill attempt has ever run**, and at one benchmark
  per day the queue had reached only SPY.
- That one attempt most likely died on the **harness bug fixed hours later the
  same day**: the operator had set the global harness to codex, `:trading_read`
  was not yet pinned to claude, and codex answers claude's `--disallowedTools`
  with `unexpected argument` and exit 2. Every trading-tier run in that window
  failed the same way.
- **The fetch itself works.** Running the recorder's exact chart-tier call for
  SPY against Robinhood returned a full year of clean OHLCV, oldest first:
  `111.2s`, 3 turns, `is_error: false`, **$0.57**. So there is no ceiling
  problem, no span refusal and no timeout — the 300s cap is comfortable.

Three structural properties remain true and are worth keeping as **risks rather
than as a diagnosis**:

1. **The latch marks the attempt, not the success** (deliberate, documented). A
   failing backfill consumes the day.
2. **One benchmark per day.** Four benchmarks is four clean days; a watchlist of
   N symbols is N days before it can draw an advanced chart.
3. **The failure is invisible.** `backfill_benchmark/2` returns `{:error, …}` and
   the recorder writes a `Logger` line; nothing reaches the Sentinel feed —
   confirmed by querying `security_events` and finding no benchmark messages.
   That invisibility is what made one attempt look like an established failure,
   including to this document.

**And the number nobody had: $0.57 per deep backfill**, measured. That is the
unit economics of the whole feature — a 20-symbol watchlist costs ~$11 to seed
and, at one per day, twenty days to fill.

**With Finnhub ruled out on 08-04, that number is not a placeholder.** Every
remaining cheap path is worse: Alpha Vantage is 25 requests/day by its own
registry note "a demo, not a data source", Yahoo's endpoints are `:unsanctioned`,
and dropping to sonnet saves ~40% on a surface where the only measured failure
mode is silent fabrication. Deep history costs about half a dollar a symbol, and
the honest thing is to price it in the UI rather than keep looking for a way out
of it.

**The sweep has a hard cap of 10 symbols**, and anything past it is skipped BY
NAME rather than silently (`market_data_prompt/1`, and the `:skipped` warning in
`refresh/1`). This is the constraint that shapes the whole feature: a watchlist
is not free, and an unbounded one silently degrades the sweep it shares.

**Still not determined:** whether the one failed attempt was in fact the codex
bug. The evidence is circumstantial — right window, right symptom, no durable
record either way, which is exactly the gap Phase 1 closes.

---

# Phase 0 — Why the benchmarks are empty — **DONE 08-04**

- [x] **Ran the real `fetch_symbol_bars("SPY", -370d, "day")`**, driving the CLI
      directly with the recorder's own prompt, tools and MCP config so the dev
      server was never touched. Result: a full year of bars, `111.2s`, 3 turns,
      `is_error: false`, `$0.5667`.
- [x] None of the three candidates hold. Not (a) a span refusal, not (b) a
      transcription timeout — 111s against a 300s cap — and not (c) auth or
      allowlist.
- [x] **The answer is "it has barely run".** One attempt, one day old, in the
      window where the codex harness bug broke every trading-tier run.

**So deep backfill is viable, and "advanced charts" can honestly promise a year.**
The thing to fix is not the fetch; it is that a single silent failure was
indistinguishable from a broken feature — for a whole afternoon, to the Chart
Build agent, the operator, and this roadmap.

## The cost, and the operator's call on it — DECIDED 08-04

**$0.5667 per deep backfill, and every cent of it is model work.** Measured, with
the breakdown:

```
claude-opus-5   $0.5659      output_tokens   8,922
haiku-4-5       $0.0008      cache_creation 30,551
                             cache_read     74,576
```

Robinhood charges nothing for the tool call. The cost is **transcription**: the
MCP tool returns bars as JSON, and the model retypes them as different JSON —
8,922 output tokens of copying, under a prompt that says "transcribed exactly —
never invented". A frontier model as a careful photocopier.

Three cheaper paths were identified and **all three declined for now (operator,
08-04): stay on the $0.57 path.**

- **Finnhub candles — MEASURED 08-04, and the answer is no.** `/stock/candle`
  returns **HTTP 403, "You don't have access to this resource"**, with a key
  whose `/quote` returns 200 in the same minute — so it is a tier restriction,
  not auth. There is no free OHLC history there, and this was the most promising
  of the three cheap paths. It is now closed rather than pending, and the
  registry entry says so.
- **Sonnet on `:trading_read`** — permitted (it is the floor, not below it), and
  roughly 40% cheaper by arithmetic on the token counts above. Declined because
  the 07-28 fabrication finding measured *haiku*, says nothing about sonnet
  either way, and this surface transcribes financial data where one wrong digit
  is silent. Cheaper transcription is exactly the axis on which the Chart Build
  agent's refusal-to-invent would degrade quietly.
- **Alpha Vantage** — 25 requests/day is useless interactively but would in
  principle cover one backfill per day. Registry status `:candidate`, and its
  own note calls it "a demo, not a data source".

**What this means for the watchlist:** the list itself is free (a `Settings`
row), and charting anything already cached is free forever. The $0.57 is a
one-time seeding cost per NEW symbol, and ongoing top-ups ride the existing daily
sweep in a batch. So the honest framing in the UI is a per-ticker admission price,
not a subscription.

# Phase 1 — Make the failure visible, whatever it turns out to be

Independent of the diagnosis, and small.

- [ ] `backfill_benchmark/2` failures land on the **Sentinel feed**, not only in
      `Logger`. Today the app cannot answer "did the backfill work?" from
      anything durable.
- [ ] The Chart Build data panel (or the source note) says when a symbol's
      history is **short because a backfill failed** versus **short because the
      symbol is new**. Those look identical today, which is why the agent had to
      guess at tea leaves.
- [ ] Consider whether the attempt latch should still consume the day on a
      *failed* run. It exists to stop re-spending agent runs — but the current
      shape converts one bad day into permanent absence. A bounded retry (say two
      attempts) keeps the spirit without the trap.

# Phase 2 — The watchlist

- [ ] A watchlist of symbols the operator names, stored where the operator's
      other choices live (`Settings`, not a seeded workspace file — the V.8
      upgrade-path problem applies).
- [ ] The daily sweep discovers **holdings ∪ watchlist**, and the deep backfill
      considers **watchlist ∪ benchmarks**. One union, not a second pipeline: a
      symbol that is both held and watched must not be fetched twice.
- [ ] **The 10-symbol cap is the real design constraint.** Holdings already
      consume it. Decide explicitly: does the watchlist share the cap (and whose
      symbols lose?), or does it get its own pass? Whatever is chosen, the app
      must say which symbols were skipped — the sweep already names them, and
      that naming must survive into the UI rather than staying a `Logger.warning`.
- [ ] Removing a symbol from the watchlist must not delete its bars. Cached
      history is expensive to reacquire; the watchlist governs *what gets
      fetched*, never *what is kept*.

# Phase 3 — Advanced vs short-term charts

The operator's distinction, made real rather than implied.

- [ ] `MarketData.chartable_symbols/0` gains a notion of **depth**: a symbol with
      a year of bars can be charted over a year; one with six can be charted over
      a week. The Chart Build agent already refuses to substitute or extrapolate
      — this gives it the vocabulary to say *which* chart it can draw instead of
      only which it cannot.
- [ ] The chat surface should be able to answer "why can't you chart NVDA" with
      the actual reason (not held, not watched) **and the gesture that fixes it**
      (add it to the watchlist), rather than advising the operator to open a
      different tool and read the source. That exchange is the reason this
      roadmap exists.
- [ ] Indexing to 100 at a common start — which the agent proposed unprompted —
      is the right answer for comparing magnitudes and should be a first-class
      option once more than one symbol has real depth.

# Phase 3.5 — A shared left sidebar, on the workspace's bumper

**Operator, 08-04:** the **data panel and the watchlists share one left sidebar**,
collapsed by a bumper, built like the one in the **Workspace** tab.

**Correction to this file's first draft**, which claimed the app has "exactly one
bumper" and pointed at `CornerWidget`. It has **three**, and they are not
interchangeable — that claim was made from one grep of two directories and was
wrong:

| pattern | where | how it works |
|---|---|---|
| `CornerWidget` | homepage corner card | JS hook, `ic-corner-bumper`, **right** edge, animated pop-out |
| **Workspace sidebar** | `workspace_live.ex:265-292` | **pure LiveView** — `@sidebar_open`, `phx-click="toggle_sidebar"`, a `w-2.5` strip with a flipping chevron. No hook, no custom CSS. |
| `#bumper` | native browser shell (`chrome.js:836`) | its own DOM + ⌘B, outside the LiveView world entirely |

**The workspace one is the target, and it is the cheapest of the three**: a
sibling `<button>` beside the panel, `border-y-2 border-r-2`, `bg-primary/15`,
`hero-chevron-left` / `hero-chevron-right`, and a boolean in the LiveView. No
JavaScript at all. Copying it is a dozen lines; reaching for `CornerWidget`
would drag in a hook and an animation for a job that does not need either.

- [ ] One left sidebar in the Trading tab holding **both** the data panel
      (`trading_account_card` / `chart_preview`) and the watchlist UI. They share
      the collapse: one bumper, one boolean, not two panels each with their own.
- [ ] Decide how the two stack inside it — the data panel is tall and scrolls
      (`overflow-y-auto`) and the watchlist is a list that also wants to scroll.
      Two independently scrolling regions in a fixed-height column is the actual
      layout problem here, and it is the reason to look at the real tab before
      writing markup.
- [ ] This is a **layout change to every Trading tab kind**, not just Chart
      Build: Robinhood, Chart Build and a neutral chat all render that data panel
      today. The neutral-chat case already has a bespoke "no data panel of its
      own" branch (`trading_live.ex:2261`) that will need to say something
      sensible when the sidebar exists but has nothing but watchlists in it.
- [ ] Named lists, per the operator's plural — see Phase 2, where the storage
      shape has to be decided rather than retrofitted.
- [ ] Each ticker row shows **how much history the cache holds for it**, so
      "advanced" versus "short-term" is visible where the symbol is added rather
      than discovered when a chart comes back wrong.
- [ ] Collapsed is the sensible default on a tab that already carries a tab
      strip, a chat window and a data panel — but the workspace's own default is
      **open**, so this is a deliberate difference and should be one, not an
      accident.

# Phase 4 — Only if it earns it

- [ ] Watchlist symbols that are neither held nor benchmarks still cost a fetch
      per day forever. A "stop tracking after N days untouched" policy is
      obvious and premature: nobody has hit the cost yet.

---

## Order

**Phase 0 is not optional and is not a formality.** Every later phase assumes
deep backfill works. It currently produces zero rows for four symbols, and the
reason is unmeasured. Building a watchlist on top of a broken backfill produces a
UI that lets the operator queue disappointments.

**Phase 1 before Phase 2**, because the thing that made this hard to diagnose was
not the bug — it was that a failing daily job looked exactly like a working one.
Adding more symbols to an invisible pipeline makes that worse.

**The question to ask every phase:** does this let the operator ask for something
the cache cannot deliver, without saying so at the moment they ask? The Chart
Build agent's refusal to substitute NVDA or stretch a 3-month window is the
behaviour to protect — a watchlist that silently fails to populate would turn
that honest refusal into a confusing one.
