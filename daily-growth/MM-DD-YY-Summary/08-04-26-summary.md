# 08-04-26

Twenty-one commits, two roadmaps closed and archived and a third opened.
Yesterday's through-line was written claims coming apart from code. Today's is
the sequel and it is less comfortable: **the suite was green through all of it,
and an operator using the app found three bugs it could never have caught.** Not
because the tests were bad, but because every one of them assumed the thing that
had just stopped being true — and the last of the three raised no error at all.

A second thread runs through the afternoon and is worth naming separately: **two
of the day's documents were wrong within an hour of being committed**, and both
were corrected by running something rather than by rereading them. One claimed
the CLIs do not report spend; one called a single failed attempt a structural
failure. Writing a thing down does not make it measured.

## Phase 4 was a much smaller build than its own roadmap said, because the roadmap was wrong

The line read: *"Cost reporting per surface. Attractive, and a much bigger build
than it sounds — the CLI does not report spend back to us."*

It does. Claude's `result` event carries `total_cost_usd`, `usage`, `num_turns`
and `modelUsage` — measured at `0.0802325` on a one-word prompt. Codex reports
token counts on `turn.completed`. OpenCode reports an actual dollar `cost` on
`step_finish`. **All three, all along.**

The tell had been sitting in the tree the whole time: `StreamEvent` has parsed
`total_cost_usd` since before any of this started. A parser that reads a field
the roadmap says does not exist is a contradiction nobody had looked at.

That claim had been copied into the agent-backend roadmap, the Explore tutorial,
the daily summary, `AgentBackend`'s own descriptor, and four messages to the
operator — all in one day, all by the same session that kept insisting on
measurement. **Seventh instance in two days of a written claim disagreeing with
the tool.** Corrected in all five places, with a test that refutes the old
wording so it cannot drift back.

What shipped instead of a big build: `StreamEvent.usage` normalizing
input/output/cache/cost across three measured shapes, and `run_usage/2` for the
blocking surfaces that hold the whole stream as one string. **Codex's cost stays
nil and must not be derived** — a price table this app does not own would make an
invented number look authoritative.

## The reversal: money surfaces are pinned to Claude

Yesterday the operator chose to allow any harness on trading reads and order
submission, with a loud warning, over the recommendation to keep them
Claude-only. That call was made with the cost stated and was reasonable on the
information available.

The information was incomplete. Both money surfaces hardcode Claude's
confinement vocabulary — `--allowedTools`, `--disallowedTools`,
`--strict-mcp-config` — and codex answers those with `error: unexpected argument
'--disallowedTools'`. Measured, not assumed.

So selecting codex there produced a run that **failed every time**. Not
cheap-and-unsafe: broken. And the warning shipped the day before said *"No floor
here… running unprotected"*, which implies it works and is merely unprotected.
The UI was misleading in the one place it most needed not to be.

Pinned instead, with `put_backend/2` refusing the choice and the Settings row
explaining why there is no picker rather than offering one that fails.
`unfloored_money_surfaces/0` is kept as a **live assertion** rather than deleted:
lift the pin without giving the floor a per-backend measurement and it starts
returning entries and its test fails. The pin and the floor have to move
together.

This also made Phase 4's other half moot in its original form. The per-backend
fabrication probe was the gate on a per-backend floor — but with no non-Claude
money run possible, there is nothing left to measure. The closeout says that
plainly instead of leaving a checkbox that reads as pending.

## The first two bugs the operator found, and why the suite could not

**The global harness had no picker.** Every per-surface row got a harness
dropdown; the global default never did. So the only harness reachable from
Settings was whichever one PATH detection happened to find — the command could
set it, the UI could not. Everything read `claude` because nothing else was
reachable.

**Claude-only flags leaked into a codex argv.** Switching the harness made every
chat turn exit 2 with `unexpected argument '--append-system-prompt'`. The stream
flag and the resume flag had been made harness-aware; two more sitting in the
same list had not. `extra_cli_args` was the worse of the pair — the Trading chat
carries `--strict-mcp-config`/`--allowedTools`, so that conversation would have
failed every turn on any other harness.

**Neither was catchable, and the reason is specific:** until the fix, the suite
had **no test that ran a chat on a non-Claude harness at all.** Every chat test
implicitly assumed claude, so the entire class was invisible — 2,500 green tests
saying nothing about it. Coverage measured against the world as it was before the
feature existed proves the feature is not broken only in the ways it used to
not exist.

There are now four such tests, asserting on the argv the production path builds.
The same gap plausibly exists for the dispatcher and swarm surfaces, which have
also never been exercised on another harness — flagged rather than assumed
harmless, since "I don't expect a problem there" preceded both of today's misses.

## `nil` is representable twice, and both spellings bit

Two bugs in one module, same shape:

`backend_for/1` matched the absent case with an `is_atom/1` guard. **`nil` is an
atom.** A surface with no override returned nil rather than falling through to
the global default, so per-surface overrides worked perfectly and the global
default never worked once.

`known_models(nil)` returned `[]` rather than claude's list, because passing nil
explicitly bypasses a function's default argument. Unset is the state every
install starts in — so on a fresh install the model picker was empty.

Both were caught by tests written the same hour, neither by reading the code
twice. "Unset" keeps being expressible as `nil` or as absence, and only one gets
handled.

## Three days of a dev server, and a config it predated

`on-duty` failed with `missing secret_key_base for Google credential vault`. The
config sets it; a fresh VM resolves it; the error was real.

The server serving port 4000 had been running since **Aug 1 12:18** — about 32
hours *before* the commit that added `config :buster_claw, secret_key_base:`.
Phoenix's code reloader swaps modules; application config is read **only at
boot**. So a VM was running modules that call `RuntimeConfig.secret_key_base!/1`
while its own app env had never contained the key.

It surfaced three days late, in a subsystem unrelated to the change, with a
message that reads as "you forgot to configure this" rather than "this VM
predates the configuration". The endpoint's own key was set long ago, which is
why the web UI worked fine and only vault-backed paths failed — a partial
failure that pointed away from the cause.

## The backend roadmap, closed

Two backends existed in code and one existed in practice. Now three do, the
operator picks, and the picks are honest about their limits: harness chosen
globally and per surface, models keyed on `{backend, surface}` so switching is
lossless, per-backend stream parsers built from **captured** output, and the
harness recorded on the audit trail for every money-surface run (the last open
item from the floor problem).

Archived to `08-04-26-agent-backend-roadmap.md`. Two items went to LEFTOVERS with
the prerequisites that make them real work rather than one-liners: **cost
aggregation** cannot be per-surface until the dispatcher and swarm stop dropping
their result event on the floor (three of six surfaces would silently total
zero), and **`opencode models` must be cached** before anything calls it, because
today the only thing keeping a subprocess spawn out of a LiveView render is a
docstring.

Two probes were never settled and are named as the first work if this reopens:
whether `codex exec --ignore-user-config` can scope MCP to Robinhood alone, and
whether an OpenCode agent file's permission patterns reach individual MCP tool
names. Both decide whether per-backend confinement is buildable at all — which is
what the pin is waiting on.

## Codex gets a model list, and the provenance goes in the code

Picking codex left the model dropdown empty with only a note pointing at the
free-text field. It now offers `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`.

This reverses "ship no list for a harness that cannot enumerate". That rule's
reason — a fixed list goes stale — is real, but the free-text field already
covers it, and the cost of no list was every codex user typing an ID by hand for
no benefit. OpenCode still ships none: its list is genuinely per-machine.

The part worth keeping is *how* the IDs are recorded. **Codex does not validate
the model up front** — `definitely-not-a-model` was accepted and passed straight
to the provider — so a wrong entry fails late and confusingly rather than at the
picker. So each ID carries its evidence in the code: `gpt-5.6-sol` from the
operator's own `~/.codex/config.toml`, `gpt-5.6-luna` from `opencode models`, and
`gpt-5.6-terra` named by the operator and following the family pattern but **not
independently verified**. Three IDs that all *look* equally checked would have
been the more comfortable thing to write and the less useful one.

## The empty Trading chat: one decision held in two places

Then the Trading tab went blank. Not an error — blank.

Two commits earlier, stopping claude-only flags from leaking into a codex argv
meant `start_run` began spawning with `effective_agent/1`: a conversation
carrying claude-only confinement runs on claude whatever the operator chose.
`apply_line` kept parsing with `state.agent`, which said codex.

So the tab spawned claude and read claude's `stream-json` through the **codex**
normalizer. Every event fell through to `:unknown`. Nothing reached the
transcript.

**Nothing failed.** The run succeeded, the output was correct, the exit status
was 0 — the parser simply understood none of it. An empty window was the entire
symptom, which is why it read as an integration gap rather than a bug.

The general shape deserves the name more than the instance does: **the argv and
the parser are two halves of one decision**, and holding that decision in two
places was harmless with one harness and silent with three. They now come from
one function.

The regression test was probed by reverting the fix, and fails without it. That
mattered here specifically: the previous version of that same test file passed
happily while the app rendered nothing.

## The day in one line

Yesterday's lesson was *measure the tool rather than quoting the last person who
did*. Today's is its other half: **a green suite is evidence about the questions
it asks, and a new capability arrives with its own questions unasked.** All three
bugs that reached the operator today were in code paths no test had ever walked,
in a suite that had grown by two hundred tests that week — and the third one
produced no error at all, just an empty box where the answer should have been.

The common factor every time was a path never exercised on a non-claude harness.
That is now a named piece of outstanding work rather than a hope: audit every
argv- and stream-handling path — dispatcher, swarm, Chart Build — instead of
waiting for the fourth.

# Later the same day: the market cache learns what you care about

## An agent refused honestly, and was right about nearly all of it

The Chart Build agent was asked for a year of NVDA and SPY beside QXO. It drew
what it had, said plainly that NVDA and SPY were not in the cache and it would
not substitute, said the window was three months rather than a year because that
is all the cache held, and offered to index to 100 so three magnitudes could be
compared honestly. Asked how to add them, it said it could not do it from there,
inferred the mechanism from what the cache contained, and flagged one of its own
inferences as *"a real thing to check rather than assume"*.

Reading the code confirmed the inference and narrowed it: **a symbol enters the
cache by being HELD and by nothing else** — `MarketData.refresh/1`'s prompt opens
"Collect market data for the operator's holdings". There is no watchlist because
there was never a mechanism for one. And the thing it flagged as worth checking
was the thing that mattered.

## A roadmap written from one sample, corrected by one measurement

The four benchmarks (SPY, QQQ, DIA, IWM) had zero rows while the attempt latch
read today. The roadmap written in response said the backfill "runs and yields
nothing" and called the failure durable, citing three structural properties.

Then the recorder's exact chart-tier call was run for real: **a full year of
clean OHLCV in 111 seconds, 3 turns, `is_error: false`, $0.5667.** Not a span
refusal, not a timeout against the 300s cap, not auth.

The truth was arithmetic: the feature landed 08-03 at 21:07, after that day's
fire time; at one benchmark per day **exactly one attempt had ever run**, and it
fell in the window where the codex harness bug broke every trading-tier run —
the bug fixed hours later in this same session. A one-sample failure had been
written up as structural, in a document committed an hour earlier.

The three properties survive as **risks** rather than as a diagnosis: the latch
spends the day on a failure, one benchmark per day means N symbols is N days, and
the failure reached `Logger` but never the audit feed. That third one is why a
single attempt looked like a broken feature to the agent, the operator and the
roadmap simultaneously.

SPY was then seeded from the probe's own output — 254 bars, validated through the
app's own tripwire (parseable date, positive prices, high ≥ low), 0 dropped.

## $0.57, and all of it is the model typing

The cost of a deep backfill, measured and broken down: **$0.5659 of $0.5667 is
Opus**, 8,922 output tokens. Robinhood charges nothing. The money is
*transcription* — the MCP tool returns bars as JSON and the model retypes them as
different JSON, under a prompt that says "transcribed exactly — never invented".
A frontier model as a very careful photocopier.

Three cheaper paths were identified and all three declined for now: Finnhub
candles (wired and verified, but it implements only `quote/2` and `news/2` — one
call would settle whether the free tier serves candles, and it is the first thing
to try if cost ever bites), sonnet on `:trading_read` (~40% cheaper, permitted by
the floor, declined because the 07-28 finding measured *haiku* and says nothing
about sonnet on a surface where one wrong digit is silent), and Alpha Vantage,
whose own registry note calls it "a demo, not a data source".

The framing that follows: the watchlist itself is free — a Settings row — and
charting anything already cached is free forever. The $0.57 is a per-ticker
admission price for **new** history, not a subscription.

## Phase 1: the record that was missing

`MarketData.backfill_status/1` now answers the only question anyone asks of that
cache — *why is this symbol's history short?* — with `:deep`, `{:failed, on,
reason}`, or `:never_tried`, kept per symbol rather than as one global day-latch.
Outcomes land on the Sentinel feed, successes included, so the trail shows work
rather than only breakage.

Not changed, deliberately: the latch still spends the day on a failure. A bounded
retry doubles worst-case daily spend on a persistently failing symbol, and after
an explicit decision to accept $0.57 that is the operator's call rather than a
cleanup to slip in.

## The rail, and a misread that took two rounds and one screenshot

Watchlists landed as named lists in `Settings` — plural, because that was the
word — with a left rail on the **Workspace tab's** bumper: a `w-2.5` sibling
button, a flipping chevron, a boolean. No hook, no CSS. (An earlier note in this
same roadmap claimed the app had "exactly one bumper" and pointed at
`CornerWidget`; it has three, and the cheapest was the one asked for. Corrected
in place.)

Then "the data panel and the watchlists share the left sidebar" was read as *the
Robinhood account UI*, and the whole card was moved into the rail. Wrong — and
the suite said so immediately for a different reason: the rail defaulted
collapsed, which was right when it held only watchlists and meant **opening
Trading to an empty page** the moment the panel moved in. Six tests failed on one
line whose value never changed, only its meaning.

The move was reverted. One screenshot then resolved in a second what two rounds
of inference had not: **the ticker lookup**, not the account UI. It now sits in
the rail above the watchlists, on both Robinhood and Chart Build.

Its banner did not travel with it. *"Public data only — this chat cannot see your
accounts"* is a claim about the **chat**, not the search: it says Chart Build's
chat has no Robinhood tool to deny. On the Robinhood tab that sentence is false —
that chat can see your accounts, which is what it is for. So the lookup shows on
both kinds and the banner stays on one, with a test asserting its absence rather
than a comment promising it.

## What the rail says on every row

Each ticker carries `year` / `N bars` / `failed` / `queued`, read from
`backfill_status/1` so the rail and the recorder cannot disagree. "6 bars" and "6
bars because the fetch died" were the same observable state this morning. And the
rail states in as many words that adding a symbol records intent rather than
spending money — because at $0.57 a ticker, "add to a list" and "spend" must not
be the same gesture.

Keyboard navigation followed: arrows walk the matches, Enter opens, Escape drops
the highlight — `phx-keydown` and an index, no hook. The real work was not the
arrows but resetting the cursor everywhere the matches change, since an index
pointing at a row that no longer exists is exactly the bug the feature invites.

## Still not wired, and worth saying

**The sweep does not read the watchlist.** A ticker added today shows `queued`
and stays there. That is the rest of Phase 2 and it is where the decisions are:
the sweep caps at ten symbols, holdings already consume part of that, and
somebody has to decide whose symbols lose when the cap binds.
