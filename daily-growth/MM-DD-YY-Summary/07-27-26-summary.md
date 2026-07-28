# 07-27-26 — Every account, and what the money actually did

The Trading tab showed one account. It now shows all of them, and charts the
gain across them going back to January 2024.

The theme is **what the API will not tell you.** Robinhood's agentic MCP has no
portfolio-value history and no transfers endpoint — both confirmed by probing
the full 50-tool surface, not by reading docs. So the day split into two halves:
making the panel show every account honestly, and then becoming the recorder for
a history nobody else keeps.

Almost every defect found today was caught by **running the real thing**, not by
the suite. The suite was green at every one of those moments.

2 commits, 28 files, +5860/-115. Suite at close: 1538 tests, credo/Rust clean.

## 1. The panel was never broken — our stopwatch was

Multi-account landed, and then "the accounts don't seem to be loading." The
fetcher's wall-clock cap was `90_000`ms, inherited from when the snapshot was
one account. The real multi-account fetch measured **105 seconds**. The run was
being killed at 90s and surfacing as "agent run failed."

The data was never the problem. Worth remembering because the symptom pointed
squarely at the new code and the cause was a constant nobody had revisited.

## 2. Two stages, because 105 seconds is not a spinner

Splitting breadth from depth: stage 1 fetches balances for every account (~28s
measured) and renders chips immediately; stage 2 fetches one account's holdings
when its chip is selected. Switching to an already-loaded account is instant, and
the Crypto account — which has no positions tool at all — is never fetched.

Stage 2 identifies its account by **last four digits**, re-resolving the real
number from `get_accounts` at call time. That costs one cheap tool call and keeps
full brokerage account numbers out of the Settings cache entirely.

Which matters, because:

## 3. The model returned unmasked account numbers

The prompt asks for `"<masked account number>"`. The model returned
`801666587`, `515468262`, `971268735` verbatim. Masking now happens in
`normalize_account/1` — enforced app-side, never a request the model can decline.
Ids that collide on their last four get a suffix so no chip becomes unselectable.

**The general rule this is an instance of:** a formatting request in a prompt is
a preference, not a constraint. Anything that must be true has to be true in the
code that receives the output.

## 4. "Can't read it" and "there is nothing to read"

A crypto account reports a real balance and no holdings, because the tool surface
has no crypto positions endpoint. The old copy would have rendered that as "No
positions — the account is all cash," which for a funded account is simply false.
Four distinct states now get four distinct lines: unreadable, loading, failed,
and genuinely empty. There is a test asserting the all-cash sentence does *not*
appear for crypto.

Same principle drove stage 1 leaving `positions` **absent** rather than `[]`.
An empty list claims we looked.

---

# The portfolio ledger

`daily-growth/roadmaps/PORTFOLIO_HISTORY_ROADMAP.md` — scoped against the probed
API, with the constraint that shaped everything stated first: **there is no
portfolio-value history to fetch.** A day we fail to record is gone for good,
while a day we record *wrongly* deforms the chart for as long as the row lives.
The ledger prefers a gap to a guess, everywhere.

## 5. Phase 0 — the ledger, and one honest deferral

One row per account per market day, integer cents, idempotent. Two gates between
a model-sourced float and a permanent row: cents conversion done once, and an
order-of-magnitude check.

Shipped with the timezone question **open and documented** rather than quietly
resolved: `LocalTime.today/0` is machine-local, and on a Pacific machine that
names tomorrow between 9pm and midnight. Adding a dependency is an operator
decision, not a detail to sneak into a phase that didn't ask for it.

## 6. Phase 1 — market days, and a dependency with a bill

tzdata added, autoupdater disabled — a silent HTTP call to iana.org from an app
whose whole posture is "no unannounced outbound requests" is exactly what that
posture exists to prevent. **It pulled in hackney and 7 transitive deps**, which
is a real cost in a DMG and was flagged rather than absorbed.

`MarketCalendar` computes NYSE holidays rather than tabulating them, including
the exchange's exception where a Saturday January 1 does *not* close the
preceding December 31. Verified against the published calendar for 2025–2027.

The UTC fallback is **loud**. The first version fell back silently, which
reintroduces the precise bug tzdata was added to fix. A test now asserts a real
Eastern offset, so a future dependency change fails the suite instead of quietly
misfiling readings.

## 7. Phase 2 — and the gate that was suppressing its own evidence

Deposits and withdrawals are entered by hand (no transfers API) and gain is
computed around them. `not_a_transfer` is a real answer — without it the anomaly
prompt could never be told "no" and would nag forever.

Then the LiveView test failed for a reason worth recording: **Phase 0's sanity
gate rejected the deposit.** Funding a $3.38 account with $500 is a 149× jump, so
the fold test threw the day away — and with it the prompt that would have
explained it. The gate was suppressing exactly the event Phase 2 exists to
handle.

Now it requires *both* a fold violation and a move of at least $5,000, which is
what model garbage actually looks like: a units error, not an ordinary deposit.
Ratios on small numbers are noise — the same reasoning already justified the
anomaly floor, which is what made the gate look suspicious.

## 8. Phase 3 — the backfill, and an asymmetry

`get_realized_pnl` at span "all" returns **monthly** buckets back to 2024, with
`null` (not zero) for months without closing trades. `realized_cents` is signed,
deliberately unlike `value_cents`: February was −$1,076, and a non-negative
validation copied from the snapshot schema would have discarded the most
important point in the series.

One of three accounts failed its backfill to a transient MCP outage, which
exposed an asymmetry worth naming. The recorded side refuses to draw a partial
total — a missing account renders as a cliff. The realized side **can't** take
that line, because one flaky backfill would hide years of history. So it degrades
differently: the total is drawn and is *understated*. That is a quieter failure
than a cliff, which is exactly why `backfill_coverage/0` exists to say it out
loud.

## 9. Phase 4 — the chart, and the bug the tests could not see

Server-rendered SVG. Gaps are gaps, zero is always in frame, downsampling keeps
the **last** point per period (a mean of running totals is a number that never
existed) and says which granularity is showing.

Then running the real 32-point series through the geometry: **the 1M view drew
no line at all.** Two points straddling the seam — one realized, one recorded —
made two single-point chunks, both dropped.

The cause was treating two different things as one. A *gap* means a trading day
went unmeasured, so the new path must start clean. The *seam* means the line
genuinely continues and only its meaning narrows, so the new path repeats the
previous point and the style changes mid-line. Without that distinction the chart
visibly contradicted the "one continuous line" that the entire single-axis
argument rests on.

25 chart tests were green while this was broken. The probe found it in one run.

## 10. Phase 5 — readable, and one addition the roadmap didn't ask for

Crosshair, arrow-key navigation, an `aria-live` readout, and a table view listing
exactly the plotted points so it can never disagree with the line. Hover,
keyboard, and screen reader emit the same sentence because it is built once on
the server.

**Transfer marks** were added beyond scope, and the reason is the point: netting a
deposit out of the gain is correct, and it means a $500 transfer leaves *no
trace* in the line. Without a mark, the arithmetic is unverifiable by the person
whose money it is. Flagged days now carry a tick on the plot, a phrase in the
tooltip, and a column in the table.

## What today keeps teaching

Every real defect — the 90s cap, the unmasked numbers, the gate eating deposits,
the broken seam — was found by running the actual thing against actual data. The
suite was green each time, and the suite was not wrong; it was answering
questions we had thought to ask. The probes asked the questions we hadn't.
