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

---

# Second session — the evening proper

Everything above was written at 22:56 and closed the previous working session;
by the convention §9 set (date it by the date that has actually happened) it and
what follows share this file. Three minutes after that commit the wallets
subsystem came out (`db10a58`) — the whole context, its four tables, and the
journal/introduction/chat tightening that fell out of it. Then the evening's own
arc, which is a build-and-delete: `5ee249f..a8a20e3`, four commits, and the net
line count is **negative**. Two more followed once the tab was pointed at the
real broker (`c52c6f1`, `268ca28`), the second of which corrects the first.

## 10. The order lane, built and then removed

A full deterministic trade lane was authored and committed *as a checkpoint so it
could be deleted safely*: `TradingOrders` with a draft→review→policy→confirm
intent chain, `TradingBroker` carrying its own OAuth and MCP client, an order-lane
component, an OAuth callback route, a reconciler child, two tables. ~6,000 lines,
suite green.

It was reverted the same hour. The reasoning in `adc9699` is one sentence:
**trade creation does not belong in a second broker stack.** The thing that
actually prevented the chat from placing an order was never the lane — it was
`Trading.read_only_cli_args/0` (`trading.ex:212`): `--tools ""` plus an explicit
`--allowedTools` of `get_*` names, which is deny-by-default. A write tool
Robinhood adds later stays denied without a code change here. The lane was 6,000
lines of ceremony guarding a door that one allowlist already held shut.

Kept from the same batch rather than thrown out with it: AgentRunner's stdin
`/dev/null` fix, the event input allowlists, and `DataState`. The drop migration
(`20260728210000`) is `drop_if_exists` on all four tables and a no-op on a fresh
database — the tables only ever existed on a machine that ran the creates before
they were reverted.

**Committing a thing in order to delete it in the next commit is not indecision
— it is how you keep a rejected design readable in history instead of losing it
to a stash.**

## 11. DataState survives; its vocabulary does not

The five-way freshness distinction was right. Rendering it as itself was not.
"Holdings: stale · as of 3h" is the model's internal enum wearing a UI; "as of
3h" is the same fact in the user's language. `dataset_label/2` became
`as_of_label/1` — one age per panel, and on Positions it's the *price* age,
because that's the number that actually moves.

The staleness threshold went 15 minutes → 12 hours. Cost rows are written by an
explicit agent run, so a 15-minute threshold marked every panel stale a quarter
hour after the only refresh the user ever asks for. **An alarm that is always
ringing is not an alarm.** Also gone: a "Holdings: unavailable" banner rendered
directly above a populated holdings table (a partial cost load is *cached*, not
missing), and a Dividends tile whose only content was that dividends don't exist.

## 12. The model proposes in prose; the app submits from a struct

Trade creation came back to the chat without giving the chat a write tool. The
run keeps the read-only allowlist unchanged. The model gathers side, symbol,
size, type, price and TIF *in English* — the system prompt makes it **ask**
rather than default any of them — and closes with a fenced ```` ```order ````
block. `BusterClaw.TradingOrder` parses that block, validates every field, and
`TradingLive` renders **the parsed values** as a card pinned above the composer.
The click runs a separate one-shot run whose allowlist has the write tool and
whose parameters are literals from the struct.

A misread "sell 100" cannot reach the broker without the operator first seeing
`SELL 100 AAPL` rendered back from the parsed value.

Refusals chosen over conveniences at every branch: shares XOR dollars; a limit
order without a price and a market order with one are both **refused**, not
defaulted or stripped; the fence is the trigger, so explaining an order can't arm
the card, and only assistant turns are parsed (a pasted block does nothing); the
confirm event takes **no parameters**, so there is nothing in the click to forge;
and there is no retry — a run returning no verdict reports UNKNOWN and says to
check the broker, because AgentRunner's timeout kills the process group but
cannot know whether the order landed first. **Re-sending on a guess is how you
buy something twice.**

Suite at close: 1665 tests, 0 failures.

## 13. The build had been broken for six days, and nothing said so

`scripts/build_desktop.sh:76` read `rm -rf deskt`. A truncated edit in `2886f96`
(07-22) destroyed the three lines that stage the Elixir release into the Tauri
bundle:

```bash
rm -rf desktop/tauri/resources/release
mkdir -p desktop/tauri/resources
cp -R "$REPO_ROOT/_build/prod/rel/buster_claw" desktop/tauri/resources/release
```

Restored verbatim from `git show 2886f96`, and proven exact rather than
plausible: the repaired file diffed against `c808de4` — the commit *before* the
truncation — now differs only by that commit's intended change, the added
`target/debug/release` clear. Nothing else moved.

Verified: `bash -n` clean; the copy source is real (`_build/prod/rel/buster_claw`
stages to a 50M tree with `bin/buster_claw`, `erts-16.3.1`, `lib/`, `releases/`);
`desktop/tauri/.gitignore:2` still covers the staged output so the post-build
`.gitkeep` touch keeps working; and `release-desktop.yml:94` calls this script,
so every CI-built DMG picks the fix up with no second patch. A full
`cargo tauri build` was **not** run — it would only prove x86_64, which is its
own open blocker. Grepped the rest of `2886f96`'s nine files for the same damage:
clean.

**Why it stayed hidden for six days is the actual finding.** `cp` into an empty
directory is not an error, and `cargo tauri build` will happily bundle nothing.
Every DMG since 07-22 — including everything the release workflow uploaded —
carried an empty `Resources/release/` and could not boot Phoenix, and every one
of those builds *exited 0*. This is the same lesson §6 taught with a stopwatch,
arriving by a different road: the suite was green, the workflow was green, and
the artifact was hollow.

So the fix is not the three restored lines — those only undo the typo. The fix
is the guard that now follows them: the build **asserts the artifact instead of
trusting the exit code**, refusing to proceed unless `resources/release/` holds
an executable `bin/buster_claw` *and* an `erts-*` directory, and printing what it
found when it doesn't. Exercised both ways before commit — against an empty
directory (the exact 07-22 state: exit 1, named cause) and against a real staged
release (exit 0, `staged 50M release + erts-16.3.1`). A hollow bundle can still
be built by some path nobody has thought of; it can no longer be built *quietly*.

## 14. Every number on the Trading tab was invented

The operator opened the tab and said none of the accounts were accurate. They
were not inaccurate. They were fiction.

The cached snapshot held **five accounts; three exist**, totalling **$69,322
against a real $118**. Four of the five last-fours matched no account at all —
a Traditional IRA, a Crypto account, and a Margin account that have never
existed, each with a tidy round cash balance. The real accounts carry *negative*
cash (−$93.38, −$94.62, unsettled deposits); nothing invented ever does.

Worse than clean fabrication: it was **partly real**. `position_costs` held
GOOGL 0.25 @ $327.16 and 0.2014 @ $347.57 — exact matches to the broker, to the
cent — filed under account keys that do not exist, and 6587's QXO position filed
under a fabricated `4930`. Real tool output wearing an invented identity is far
harder to spot than a wholly made-up row, because every number you spot-check
is right.

### The first diagnosis was wrong, and stated as fact

I attributed it to `--strict-mcp-config --mcp-config` shadowing the
OAuth-bearing registration, ran a two-run A/B that appeared to confirm it,
removed those flags, and shipped `c52c6f1` describing the cause as verified.

**The A/B changed two flags at once**, against a failure mode that is a coin
flip. Two runs of a ~50% process is not evidence of anything. The operator's
next refresh showed no accounts at all, which is what sent me back to measure
properly:

| flags | model | broker tool calls |
|---|---|---|
| `--tools ""` (± strict mcp) | haiku | **0 of 2** |
| `--tools ""` | default | **0 of 2** |
| no `--tools`, strict mcp | default | 1 of 1 |
| no `--tools` | haiku | 1 of 2 |

`--tools ""` does not merely empty the built-in set — it takes the MCP tools
with it. The init event reports `tools:[]` and no server tool is ever callable.
Server scoping was never the bug; it is restored.

### The confinement §10 celebrated did not exist

§10 retired the order lane on the grounds that `--tools ""` plus `--allowedTools`
was already deny-by-default. Half right, and the wrong half matters:
**`--allowedTools` is an approval list, not a deny list.** Under `dontAsk` a
built-in merely *absent* from it still runs. Probed directly: asked for `Bash`
with only the Robinhood tool allowed, got a clean execution and an empty
`permission_denials`.

So the door was held shut by `--tools ""` alone — the same flag that was
breaking every read. Removing it to fix the data would have opened the shell to
the trading surface, and my own previous commit did exactly that for one hour.
`--disallowedTools` refuses the built-ins by name (same probe: 0 Bash calls) and
leaves MCP working. Three flags, three distinct jobs: `--mcp-config` scopes which
servers exist, `--disallowedTools` refuses the built-ins, `--allowedTools`
pre-approves the reads.

Also retired: `model: "haiku"` on broker reads. It invoked the tool in 1 of 2
runs and **invented the answer on the miss** rather than reporting a failure.

### What actually saved this

`Trading.verified_result/1`: reads run `--output-format stream-json` and are
refused unless the stream contains a real `mcp__robinhood__*` tool-use event.
The stage-1 prompt had *always* said to emit `{"error": ...}` when the tools are
unavailable. The model ignored it and `parse_snapshot/1` cached well-formed
fiction, because **no property of a model's text distinguishes a real number
from an invented one.** A tool-use event does.

That gate is why the operator saw an empty tab instead of a fourth set of
convincing balances — and it caught *my own bad fix* one commit later. The
submit path got the same treatment with a distinction that matters more there:
no `place_equity_order` call means **nothing was sent** (safe to retry, and the
card says "Not sent"); a call with no verdict stays the UNKNOWN that forbids one.

The ledger was purged — seven fabricated account keys, the misfiled cost rows,
the poisoned snapshot cache, and on the operator's call the surviving real
readings too, since they came from the same broken path. Verified end-to-end
after the fix: **4 tool calls, three real accounts, negative cash reported
negative** — Agentic $3.65, Roth IRA $115.03, Individual $0.00. Suite at close:
1763 tests, 0 failures, credo clean.

**The lesson, stated plainly:** §9 was about not skimming a document before
telling the operator it was complete. This is the same error one layer down —
I changed two variables, got the result I expected, and wrote the explanation
into a commit message as though it were measured. A confident wrong diagnosis
is more expensive than no diagnosis, because it ends the investigation. Change
one thing. Run it more than twice when the failure is stochastic. And when the
fix is to *remove* a flag, ask what else that flag was holding up.

## The evening, compressed

Two designs were deleted today and the app got safer for it — the order lane
because one allowlist already did its job, and DataState's vocabulary because
the user does not speak enum. What survived the deletions is smaller and says
less. Then the tab was finally pointed at the real broker and every number on
it turned out to be invented — including, for one commit, by me: §14 corrects a
cause I had already written down as verified.

Meanwhile the one thing nobody was watching, the build, had been failing
silently since the 22nd behind a green exit code. **Green means the checks you
wrote passed. It has never meant the artifact works** — and the same is true of
a number on a screen. Neither the suite nor the model can tell you a balance is
real. Only the tool call behind it can.

---

# Third session — music, roadmap to working feature in one sitting

A gear change on the operator's call: music in Buster Claw. Thirteen commits
(`deea07d..0ab4af6`): a roadmap, then all six of its phases, then the operator
walked it live and it worked. The music surface closed carrying **160 tests of
its own**; the full suite ended the day at 1835. Along the way the 07-27
LAUNCH_ROADMAP consolidation — sitting untracked while three files pointed at
the four deleted roadmaps it absorbed — finally got committed (`b37c133`).

## 15. The roadmap was an inventory before it was a plan

The first hour was spent reading, not writing, and it shrank the build to
almost nothing new: `Notifications.Sound` was already an audio library with the
allowlist-as-path-guard posture, notify-settings already uploaded audio into
the DataZone with collision-free naming, two controllers already served audio,
and clipwave already decoded real files into a WGSL waveform. Three findings
did all the shaping:

- **Nothing in the app spoke HTTP byte ranges** — every audio route sent a
  whole-file 200, fine for a chime and wrong for anything you scrub. WKWebView,
  the webview that ships, is the strict case: it can refuse to seek at all. The
  one genuinely new module, so it went in early with the full RFC 7233 matrix.
- **Home tabs render behind `:if`, which destroys DOM** — a player inside the
  Music tab would die on every tab switch, a failure of the actual requirement
  that would demo perfectly. `DockLive`'s `sticky: true` mount was the answer
  already in the codebase: the player lives in the dock, the tab just commands
  it over PubSub.
- **CSP forbids one design silently**: the `default-src 'self'` media fallback
  excludes `blob:`, and CSP is Report-Only in dev, enforced in prod — a
  blob-URL player would pass all of development and fail only in the shipped
  app. Recorded so nobody optimizes into it.

## 16. What the tests caught that a demo never would

Every phase gated green, and the interesting bugs were all caught **before**
anything played a note:

- **The silent-vanishing upload.** `safe_name/1` read the extension from a
  trimmed basename while `store/2` read it from the original; `"   .mp3"`
  trims to `".mp3"`, which Elixir reads as a dotfile with *no* extension — so
  the upload passed the accept check and landed as a file `list/0` ignores.
  Success message, no track. Now both read from one place, and an invariant
  test over nine hostile names pins the rule itself: anything `store/2`
  accepts must be visible in `list/0`.
- **The sanitizer had to be wider than `Sound`'s.** Sound flattens spaces,
  which would have turned `Miles Davis - So What.mp3` into
  `Miles-Davis---So-What.mp3` and destroyed the `Artist - Title` convention
  Phase 0 built the library around — a collision between two phases that only
  exists once both do.
- **Stop-then-play erased history.** `push_history/1` returned `[]` for a nil
  track, so stopping quietly destroyed everything `previous/1` could reach. A
  pure state machine made that a one-line unit test instead of a
  weeks-later mystery.
- **The skip note that must outlive its own fix.** A corrupt file advances
  with a message — but auto-advance starts the next track within a second, so
  clearing the note on success would erase it unread. It clears on the next
  *deliberate* play, and stays true meanwhile.
- **`.m4a` crashed the tab at mount.** LiveView's `allow_upload` `:accept`
  only takes extensions the `mime` package knows, and `.m4a` isn't one — the
  whole tab failed to render, not just the picker. The picker now takes
  `audio/*` and `store/2` stays the real gate, which is the right shape
  anyway: a file the picker admits gets a refusal with a reason; a file it
  blocks is one the user can't even try.

## 17. Found along the way: nosniff is absent app-wide

Building the serving route surfaced a gap bigger than the feature:
`X-Content-Type-Options` appears nowhere in the app, and every media route is
pipeline-less — no `put_secure_browser_headers`, **no CSP header** on exactly
the responses that serve workspace files a user or agent can write. A file
named `.mp3` whose content is HTML could be sniffed, rendered, and its script
run from our own origin — the `window.__TAURI__` → shell chain the CSP exists
to break, reached by a route that never gets the header. `RangeResponse` now
sends nosniff (music + voicemail closed); four routes remain, recorded in
MUSIC_ROADMAP Part VII with `WorkspaceFileController` flagged first because it
renders workspace HTML as-is.

## 18. The operator walked it, and it worked

Upload from the tab, play, switch to Chat, navigate to `/browse`, come back —
**the music never stopped.** That closes the walk the sticky-dock design
existed for, and it was the one of the three owed walks that dev mode could
prove. Two remain, both needing a packaged build: WKWebView byte-range
behavior, and the codec probe that decides whether FLAC/OGG stay in
`accepted_extensions/0`. Conveniently, running `build_desktop.sh` for those
will also be the first end-to-end exercise of §13's staging fix and its new
assertion.

## The third session, compressed

The roadmap's best decision was made before any code: read the codebase first,
and most of the feature turned out to already exist. The best catches were all
made by tests against a state machine no browser had touched yet — and the one
thing tests could not prove, the operator proved in two minutes of clicking.
Each layer did the job only it could do. **Inventory, then invariants, then a
walk — in that order, each one cheap where the next is blind.**
