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

**Benchmarks are a separate, hardcoded path that has produced nothing.**
`@benchmark_symbols ~w(SPY QQQ DIA IWM)`, target 240 bars, 370 calendar days
back, via `backfill_benchmark/2` on the chart tier. The cache has **zero rows for
all four**, while `benchmark_backfill_attempted_on` is set to today. So the
attempt runs and yields nothing. The Chart Build agent flagged exactly this as
*"a real thing to check rather than assume"* — it was right.

**Three structural facts make that failure durable rather than transient:**

1. **The latch marks the attempt, not the success** (deliberate, and documented
   in `MarketData`). A failing backfill therefore consumes the day and does not
   retry until tomorrow.
2. **One benchmark per day.** `Recorder.backfill_one_benchmark/1` takes the head
   of `benchmarks_needing_backfill/0`. Four benchmarks is four clean days
   minimum; with failures it is never.
3. **The failure is invisible.** `backfill_benchmark/2` returns `{:error, …}` and
   the recorder writes a `Logger` line. **Nothing reaches the Sentinel feed** —
   confirmed by querying `security_events` for benchmark/market messages and
   finding none. A daily job that fails silently and re-latches is indistinguishable
   from one that is working, unless someone is watching the server output.

**The sweep has a hard cap of 10 symbols**, and anything past it is skipped BY
NAME rather than silently (`market_data_prompt/1`, and the `:skipped` warning in
`refresh/1`). This is the constraint that shapes the whole feature: a watchlist
is not free, and an unbounded one silently degrades the sweep it shares.

**Not determined:** *why* the SPY backfill returns no bars. A probe running the
real `fetch_symbol_bars("SPY", …)` was attempted and abandoned at 7 minutes — it
was run via `mix run`, which boots a second copy of the app beside the running
dev server and contends for the port and the SQLite file, so the timeout says
nothing about the fetch. **This must be measured before Phase 2 is designed**;
see Phase 0.

---

# Phase 0 — Find out why the benchmarks are empty (before designing around it)

The whole feature is "let the operator choose symbols to backfill deeply". If
deep backfill is broken, a watchlist just lets them choose more symbols that will
not appear.

- [ ] **Run `Trading.fetch_symbol_bars("SPY", ~370 days back, "day")` for real**,
      in a way that does not fight the dev server — a remote console into the
      running node, or a one-off with the server stopped. Capture the actual
      return.
- [ ] Distinguish the three candidates the result will separate:
      **(a)** the Robinhood historicals tool refuses a 370-day span for an ETF,
      **(b)** the agent run times out on a ~252-row transcription (the chart tier
      was sized for exactly this, so a failure here is a sizing fact worth
      knowing), or **(c)** the run fails for an unrelated reason (auth, tool
      allowlist, MCP config).
- [ ] If it is (a) or (b), that is a **finding about the ceiling on any deep
      history**, watchlist or not — and it changes what "advanced chart" can
      honestly promise.

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

# Phase 3.5 — Where the watchlist lives: a left sidebar with a bumper

**Operator, 08-04:** the watchlist is created and viewed in a **sidebar on the
left of the Trading tab**, opened by a **bumper**.

- [ ] **Reuse the existing bumper, do not invent a second one.** The app already
      has exactly one: `CornerWidget` (`home_widget.ex:33`, `ic-corner-bumper`),
      the tab that pulls the Calendar/Contacts card out from the edge on the
      homepage. A second bumper with its own hook and its own CSS would be two
      answers to one question — the browser sidebar's ⌘B behaviour is the other
      precedent worth reading before writing anything.
- [ ] Left edge specifically. The homepage bumper pulls from the right; this one
      pulls from the left, which is a parameter the hook may not take yet. Check
      before assuming it generalises.
- [ ] The sidebar holds **create and view**: name a watchlist, add and remove
      tickers, see what each holds. Plural is the operator's word — the storage
      in Phase 2 must therefore be *named lists*, not one flat set, and that
      decision has to be made in Phase 2 rather than retrofitted here.
- [ ] Each ticker's row shows the thing the whole roadmap is about: **how much
      history the cache actually holds for it** — a year, six closes, or nothing
      yet — so "advanced chart" versus "short-term chart" is visible where the
      symbol is added rather than discovered when a chart comes back wrong.
- [ ] It must survive a tab that is already crowded. Trading has a tab strip, a
      chat window, a data panel and now a sidebar; the sidebar collapsing to a
      bumper is what makes that fit, so the collapsed state is the default and
      the expanded one is the exception.

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
