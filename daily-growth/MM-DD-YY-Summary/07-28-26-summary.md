# 07-28-26 — The Trading tab, whole

One evening, one arc: research → roadmap → six phases → shipped. The Trading
sub-tab became a top-level surface with a real brokerage dashboard behind it —
hero and day change, positions with tax-lot cost basis, candlestick charts,
market context, earnings — on our own SVG engine, fed by one agent run per
trading day.

9 commits (34dc0e8..24066e1). Suite at close: 1662 tests, credo/Rust clean.
Every phase probed against the live API before its commit, and the probes
out-caught the suite again, every single time. The evening closed by archiving
six finished roadmaps — and by catching that I had miscounted what one of them
still had open (§9).

## 1. Research first, and the engine decision

TradingView's lightweight-charts was evaluated properly — 35KB, canvas,
baseline series, whitespace gaps, the industry's benchmark — and **declined by
the operator**: no dependency, no attribution logo, extend our SVG. The same
call as CDP-over-Playwright, for the same reasons. The library stays in the
roadmap as the bar our engine has to clear.

The UX research reduced to one hierarchy: value → day change → positions with
*what you paid* → drill into a symbol, five seconds to read. The MCP roster
already held every tool needed and unused: historicals, tax lots, index quotes,
earnings calendar.

## 2. Phase 0 — the move is the risky part

StatusLive went 2,071 → 1,110 lines with **zero** trading references; the 17
LiveView tests moved first and had to pass unchanged at the new route. The
sub-tab's contortions (last-chat dance, unread dot, per-conversation
special-casing in dispatch_chat) died with the move rather than being ported.
One behavior added: the disconnected mount spends no agent runs — a routed page
renders twice, and the throwaway static render must not cost ~28 seconds of
haiku.

## 3. The market-data spine, and two stopwatch lessons in one night

One daily sweep discovers holdings, batches the historicals call, and travels
closes as compact pairs — **payload size is a correctness parameter** when every
number transits a language model. The first live sweep died at the 240s cap
with zero output; measured honestly, the run is 213s. Same failure as the
original 90s stage-1 cap. The sweep got 480s and the measurement in a comment.

The sweep is latched **per attempt, not per success** — the Recorder re-ticks
every ~30 minutes after close, and a freshness guard alone would re-spend a run
on every tick of a failing day.

Also caught live: the index tools return `change_pct: null`. The sweep now
captures `prev_close`, and day change is OUR division over two tool-sourced
numbers — never the model's arithmetic.

## 4. The hero cannot disagree with the chart

`total_day_change/0` is the last two points of `total_gain_series` — the same
series the chart draws. Flows netted, entering accounts netted, exclusions
applied, all inherited. Tested consequence: $500 deposited + $10 earned renders
**+$10.00**. Labels stay honest: "today" only when no trading day went
unrecorded; one reading says "day change starts with tomorrow's", never $0.00.

## 5. Positions, and the nulls that carry the design

Cost basis comes from the tax-lot tools, one run per account, with the one
wrong answer named in the prompt: **never quantity × current price** — that's
market value wearing the cost's clothes. A nil basis renders "cost basis
unavailable", never $0 (free shares would gift the gain the whole purchase);
and if ANY contributing account's basis is nil, the aggregate is nil — partial
presented as whole errs in the one direction this number must never err.

First real verdict the app could deliver: GOOGL 0.4514 sh across two accounts,
basis $151.79, worth $146.76 — **down $5.03**. Everything renders from SQLite;
the LiveView test proves it by stubbing every fetcher to *error*.

## 6. Price charts invert two rules, and say so

Candles are a different question than a gain line, so: zero is NOT forced into
frame (axis reads "not zero-based"), and bars are index-spaced (a date scale
draws weekend voids into every week; each bar's real date lives in the
readout). The parser drops any bar with **high < low** — the one identity a
real bar cannot violate, the cheapest transcription tripwire available. 250
real GOOGL bars in 119s, all passing.

The probe then caught an economy bug: the API doesn't materialize today's bar
until well after the close, so coverage that demanded it re-spent a ~2-minute
run on every candle toggle all evening. Coverage now tolerates exactly one
trading day of lag — and the probe's own `false` after the fix turned out to be
*correct*, because ET rolled past midnight mid-probe. The clock is part of the
system.

## 7. Earnings, and the value of reading the schema first

One ToolSearch before prompting revealed the earnings calendar is
**market-wide** — no symbol filter exists. So the sweep calls it once over 31
days and filters to the held set it already discovered, and one-run-per-day
survived. The empty state is worded ("No earnings scheduled for your holdings
in the next month") because silence reads as "not built".

The activity panel got promoted to one shared surface that **names its gaps**:
"from 1 of 2 accounts" when only some holdings are loaded. A partial merge
presented as whole hides trades by omission.

## 8. The 71-failure scare that was neither

Mid-gate: 0 → 5 → 71 failures, `Database busy`, membership changing every run —
while a parallel session recompiled its own WIP against the same disk. The
worst "failing" suites went 78/78 in isolation, then a full clean pass minutes
later. The commit was path-scoped to exactly six files so the parallel
session's in-flight rename stayed its own. (That session independently widened
the test pool's queue window against the same contention — right fix, right
place.)

## 9. The archive, and a correction I had to make mid-sweep

`roadmaps/` went from eleven files to four live ones (Critical Path,
Distribution, Go-to-Market, First-User Review) plus LEFTOVERS and phone-maps.
Six moved to `archive/` by `git mv` so history follows, renamed to the folder's
date-prefixed convention — **each keeping its original filename inside its own
header**, because ~50 code comments cite these by name (`TRADING_TAB_ROADMAP
Phase 4`) and a grep has to keep landing.

Archived: Portfolio History and Trading Tab (both complete — Portfolio had no
closing status block, so it got one naming what the plan failed to predict);
the Browser Control field test (findings fixed, absorbed upstream, its inbound
link repointed to the archived sibling); the First-Look review (synthesized
into Critical Path, which stays live and cites it by finding number); and
Home-Chat Agent Selection — scoped 07-18, never built, archived as an explicit
decision not to pursue rather than as tidying.

**The correction.** I presented Browser Engine to the operator as "7/7 shipped,
one deferred slice" and they approved the archive on that basis. It was wrong:
**five** items were open — the four unfinished field-test repairs plus the
mirror input slice. I had read the phase list and the first clause of a memory
description instead of the roadmap's own Repairs table, two screens further
down. All five moved to LEFTOVERS with file:line pointers and blockers, and the
archived roadmap now says so at the top.

One of them is HIGH and safety-adjacent: the `/gp/buy/` payment funnel is gated
*by test* and has never been walked in a signed-in session. The field test found
that gate failing **open** on exactly that funnel. Fixed, tested, unwalked — and
archiving a document is a very effective way to end that quietly, which is why
it is now the first line in LEFTOVERS (2 items → 7) rather than page 40 of a
closed file.

**The lesson, stated plainly:** a summary offered to a decision-maker is part of
the decision. "Complete" was a claim about a document I had skimmed, and the
operator's approval was only as good as my reading. Check the table, not the
headline — especially when the answer determines whether open safety work stays
visible.

Also fixed on the way out: I had stamped every archive header `07-29`. It was
`07-28` in market time and `07-27` locally — the 29th had not happened in any
timezone. Ten files corrected.

## What the week keeps teaching, compressed

The model flake found two new costumes ("tool not callable"; the market-wide
tool it swore it couldn't reach had run an hour earlier). The suite stayed
green through every real defect; the live probes caught all of them: two
stopwatch bugs, a null the tools never fill, an economy leak, a midnight
rollover. **Run the real thing. The suite answers the questions you thought to
ask; the probe asks the ones you didn't.**
