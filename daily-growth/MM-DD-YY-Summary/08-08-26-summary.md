# 08-08-26

Built a careful way to re-home Trading. Then deleted Trading. Then deleted the
way. **~24,000 lines gone**, and the app is smaller than it has been since the
rewrite.

The through-line is not the deletion. It is that **the strongest argument for
removing something is usually what you learn while trying to keep it.** Every
fact that made the cut obvious was discovered while building the alternative to
cutting.

## The review asked for subtraction; the first answer was a mechanism

A whole-codebase critical review landed and its first finding was that the
product has no center — browser, email, calendar, trading, phone, audio,
finance, shader, journal and tutorial surfaces, each pitching something
different. Its first remedy was **subtraction**.

The first response was not subtraction. It was an extension system: a way for
Trading to leave the core download and arrive only when someone asked for it.
That is a better product than either shipping Trading or burying it, and the
roadmap for it was written honestly — its Part VII said in plain words that
**extensions reduce product surface, not code surface.**

That sentence turned out to be the whole story, written a day before it
mattered.

### What the mechanism got right

Reading the code first changed the design, which is the part worth keeping.
`BusterClaw.Trading`'s own moduledoc said the app holds no broker credentials and
speaks no MCP — so Trading was already ~85% a bundle of *data*: a URL, two tool
allowlists, three prompts, two conversation kinds. **~325 lines of data against
9,631 lines of UI.** The seam was in the code already; it did not need inventing.

The ceiling that asymmetry implied became **D1: an extension is never executable
code.** The BEAM has no code sandbox, so one loaded module holds the keychain,
the database, every token and the Tauri bridge — it makes the policy engine, the
tier system, the URL guard and the ACL lockstep test decorative in a single load.
That is a fact about the runtime, not a policy, and it is the one thing from this
work that does not expire.

The other keeper was the containment for model-authored parts: written
`enabled: false` always, install gated, an unattended run may *author* but never
*install*. The reasoning is worth restating — **a composition chaining permitted
reads into an outbound send is exfiltration built entirely from allowed steps.**
Every step authorised, the sequence not. The enable gate is where a human looks
at the sequence.

## The gate, and the door it found open

Gating Trading meant closing every door into it, and doing that surfaced one
nobody had looked at.

`Portfolio.Recorder` is supervised from boot with `autostart: true` and fires
daily after the close. All three of its duties — the balance reading, the market
sweep, the benchmark backfill — are real agent runs against Robinhood, ~28s and
cents apiece by its own moduledoc. It ran **regardless of whether Trading was
installed.**

So a fresh install with the extension off still had a daily unattended job
reaching a broker. The dock item was gone, the route showed an install card, the
split pane refused to open — and the cron kept spending money in the dark. **A
gate that stops the UI but not the scheduler is not a gate; it is a hidden link.**

That is the finding, and it only appeared because someone was trying to make
gating *work* rather than arguing about whether to gate.

## "The trading tab is still in the app"

The operator's read, and it was correct: gating had removed Trading from the
product without removing it from the codebase. Roadmap Part VII, out loud.

The call was to delete the whole thing and size the app down. Sizing it revealed
that Trading was not a feature but a **dependency chain**, and that three of the
five pieces could not be kept even if wanted:

| Piece | Why it could not stay |
|---|---|
| Portfolio (ledger, recorder) | `Trading.fetch_account_snapshot` was its **only writer** |
| MarketData (bar cache) | `Trading.fetch_market_data` / `fetch_symbol_bars` were its **only fillers** |
| Chart Build | Had **no LiveView of its own** — it borrowed TradingLive's chat, streaming and transcript |

Keeping the ledger would have left a schema nobody could ever fill. Keeping Chart
Build would have meant an AI drawing freehand SVG from pasted numbers with both
its data sources deleted.

### One thing survived the deletion by moving

`fetchable` — which data sources this app can actually pull from — lived inside
`ChartBuilder.DataReq`. It is a fact about the **source registry**, not about a
chat surface, so it moved to `Finance.Sources.fetchable_keys/0`. The distinction
it encodes is the one worth keeping: *listing is not permission.* A source becomes
fetchable by someone writing an adapter, never by being described, which is what
stops a `:blocked` entry being reachable because it happens to be in the
catalogue. `bls` lives; `market` went with the cache.

## Then the mechanism itself

With Trading gone, the extension system had zero extensions. Its tests had already
been rewritten once to stop depending on the only extension that ever existed —
which is the tell. It went the same day it was noticed: **a capability system with
no capabilities is the exact speculative breadth the review diagnosed, one layer
up.**

`Skills` returned to one directory. `Layouts.navigation_items/0` was deleted
because no dock item carries a `:surface` any more, so the filter was a fold over
nothing. `extensions/` joined `mcp/` as a retired workspace entry rather than
vanishing from the registry, so an existing folder stays declared and gets swept
when empty instead of becoming an unexplained directory.

Four mechanisms were kept **empty rather than deleted** — `ModelPolicy.@floors`,
`@claude_only`, the conversation `kind` field, `AgentToolPolicy.denied_builtins/1`
— each documenting at its definition that its only user left. The next surface
that needs a floor should declare one, not rebuild the machinery.

## Three corrections, recorded because they were load-bearing

1. **"2,838 tests, 0 failures" was not a claim I was entitled to make**, and it
   was made four times. Those runs were against a working tree carrying another
   session's uncommitted work. The committed tree had **four failures**, all
   pre-existing. Every green claim after that was verified in a throwaway
   worktree at `HEAD`, which is the only honest way to test a shared checkout.
2. **`portfolio_history` was described as reaching the broker. It does not.** The
   entire command layer contains zero `Trading.` calls; those commands read the
   *local* ledger. Acting on the wrong version would have gated three harmless
   commands and broken Chart Build, which calls one of them.
3. **Chart Build's extraction was estimated at half a day.** It was 24 call sites
   threaded through TradingLive's tab creation, layout transitions, history
   loading and streaming — Phase 4 work, not an afternoon. The estimate was
   corrected before it was planned around rather than after.

## The green test that was green for the wrong reason

`workspace_test` asserts a moved workspace gets its `buster-claw` launcher.
`WorkspaceCLI.ensure/0` writes that launcher only if it can find a CLI to point
at, and its last fallback is `./buster-claw` in the cwd — **a gitignored escript
build artifact.**

So the test passed on any machine that had run `mix escript.build` and failed on a
clean clone. It is the review's *"a clean-clone build has not been proven"* gap,
showing up as a green suite locally. Fixed by pointing the documented
`BUSTER_CLAW_CLI_PATH` seam at a real file, so the launcher path is decided by the
test rather than by whether someone happened to build an escript — then verified
by moving the escript aside and running it again.

**That is the worst way for an assertion to be environment-dependent: it is green
for whoever wrote it.**

## The day in one line

**Build the thing that would let you keep it, and you will find out whether it is
worth keeping.** The extension system was not wasted work — it produced the
account of what Trading actually was, found the unattended broker job nobody had
gated, and made the case for deletion in facts rather than in taste. Then it was
deleted too, on the same evidence.
