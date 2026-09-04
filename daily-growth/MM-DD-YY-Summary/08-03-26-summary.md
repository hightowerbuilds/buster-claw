# 08-03-26

Nine commits, three roadmaps archived, one new release gate. But the through-line
of the day is narrower than that and worth stating first, because it happened
four separate times: **a written claim and the code it described had come apart,
and only running something found it.** A palette that failed the checks it was
supposed to embody. A safety roadmap asserting orders could not be placed while
the confirm button sat wired. An OAuth subsystem described in detail that was
never in the tree. A dependency-cycle count that quietly went back up. None of
these were caught by reading — every one came from measuring.

## Chart Build ships as a fourth Trading tab kind

A `chartbuild` tab opens with a chart preview above a chat: describe what you
want, the model draws it, iterate by talking. It rides the SVG channel that
already existed — the model emits a fenced ` ```svg ` block, `SvgViewer`
sanitizes it, the preview renders it — so most of this was assembly.

**Cached-only by construction, not by policy.** `ChartBuilder` injects a bounded
snapshot into the system prompt when the conversation starts: the portfolio
ledger capped at 400 points, ≤25 symbols, ≤90 bars each. Every builtin tool is
denied. There is no code path to a live broker read, which matters because a
broker read is a whole CLI run — measured at 28s–213s and roughly one-in-six
flaky. An iteration is one chat run, and opening the tab costs nothing.

**Freehand SVG's risk is arithmetic, not security.** The sanitizer and the CSP
handle injection. What neither can check is whether the picture matches its own
numbers — a model can draw a bar chart whose bars contradict its own labels, and
it renders just as crisply either way. So every chart is labelled **drawn, not
computed**, and the skill carries the honesty rules as rules: zero in frame, gaps
are gaps, no smoothing across missing data.

## The house palette failed the checks it was supposed to embody

The `chart-builder` skill's visual section was written from imagination the day
before — a reasonable-looking list of hexes under a heading that said what good
charts do. Reconciling it against the bundled `dataviz` method meant running the
validator instead of admiring the list, and **both series colours failed the
OKLCH lightness band for a dark surface** (`#ff5a2f` at L 0.683, `#67d4ff` at
0.822; the band is 0.48–0.67).

The replacement is derived rather than chosen. Slot 1 is pinned to the in-band
step nearest the actual brand accent, and the rest were found by enumerating
steps and orderings and keeping only clean passes:

`#ff4407` · `#00a1ce` · `#9417ff` · `#e10095` · `#ac9000`

Worst adjacent CVD ΔE **16.0** against a target of 8, normal-vision ΔE **23.4**
against a floor of 15, every slot ≥3:1 on the `#111315` canvas. All-pairs — the
harder gate that scatter and bubble charts need — validates the **first four**
slots, one better than the reference palette manages.

**Two findings came out of measuring rather than reasoning.** The down-red
`#ff5c70` sits **ΔE 8.2 from the hazard orange**: on a trading chart that is a
down candle beside a price line. Searching for a replacement red made things
worse — the best candidate scraped 3.09:1 contrast and looked muddy — so the fix
is structural instead: **a chart that encodes direction does not use slot 1**.
And **dual-axis had no rule against it at all**, which on a price-and-volume
chart is the single most common way a chart lies; it is now honesty rule 8.

The rest was reconciling contradictions the first pass had shipped: "square
corners" became a 4px rounded data-end square at the baseline, "direct labels
when possible" became *selectively, never a number on every point*, monospace
ticks became one sans with `tabular-nums`. And the missing pieces got added —
pick-the-form (a lone number is a stat tile, not a one-bar chart), legend
required at ≥2 series and forbidden at one, text never wearing the series colour.

**The hover layer is documented as unavailable rather than skipped.** `dataviz`
says ship a tooltip by default; the sanitizer strips scripts and handlers, so it
is impossible. Writing that down is what makes the direct-label and
values-in-prose rules *mandatory* here instead of advisory — the honesty story
got stronger for the constraint, not weaker.

A test asserts the five hexes appear **in slot order**, because the order is the
colourblind-safety mechanism rather than decoration.

## Seeded defaults can never be upgraded, and that is bigger than skills

Chasing the stale palette surfaced the reason it would have mattered:
`Skills.ensure/0` is `maybe_write` — `File.exists?` → skip. Had the skill shipped
a day earlier, every install would have kept the failing palette permanently, and
the only fix on this machine was `rm` on the dev-workspace copy.

The pattern is not a skills problem. **Six `ensure/0` seeders share the shape**,
and the list includes `memory/policy.md`, `trusted-email-senders.md`, and
`trusted-phone-numbers.md` — the files that gate the autonomous email and phone
loops. **If a default in any of those turns out too permissive, no shipped
install ever receives the tightening.** That makes it the delivery half of every
default protection we ship, which is why it went to `LAUNCH_ROADMAP` **V.8**
rather than a backlog: whatever ships in R1 is what that cohort keeps forever,
and R1 is the handful of people whose experience we most want to be able to fix.

Never overwriting is *correct* for operator-edited files and *wrong* for an
untouched default; those two cases are currently indistinguishable, and that is
the actual problem. V.8 notes the uncomfortable half too — leaving a
too-permissive `policy.md` in place because someone once touched it is its own
failure, so a tightening baseline may belong in code rather than seeded text.
That answer got used the same day (see the egress defaults below).

## The chart chat collapses so the chart can breathe

Reading a chart meant zooming it full screen. The chat header now carries a **▾**:
collapsed, it becomes a header-only strip at the bottom and the preview takes the
rest of the height. The kind selector, thinking chip and Stop button stay
visible, so a run in progress is still watchable and cuttable.

It reuses the floating windows' `minimized` state rather than inventing a second
flag — `chat_window` already hides its body on that. The only genuinely new piece
is that an in-flow window must also **stop growing**: hiding the body while
keeping `flex-1` would have left the gap exactly where it was and made the
gesture do nothing visible.

Two consequences of sharing that state, both handled. **Unread flagging was
wrong** once collapse existed: the rule said an active Chart Build tab is always
"already showing the message," which stops being true the moment the body is
hidden — and the comment directly above that code already said *a window that is
closed or collapsed cannot be read*. The code just did not agree with it yet. And
**retyping away carried the collapse with it**, so a chat left collapsed here
would reopen as a minimised floating window with no visible composer.

Worth recording: the first version of the unread test asserted the dot while the
tab was still active, where it is suppressed by design. It failed correctly. The
test now checks from another tab, which is the only place the flag matters.

## The Trading review said orders could not be placed. They could.

`TRADING_TAB_CRITICAL_REVIEW` was archived today, but not as written, because two
of its own claims were false — and a stale safety document is worse than no
document.

Its headline recommendation is genuinely satisfied. **Stage 0 is closed and Stage
2 meets its own bar**, verified in code rather than from checkboxes: the
conversational run holds eleven `get_*` tools and no write tool, enforced by the
agent process rather than the system prompt; the model proposes in a fenced
` ```order ` block; the app parses it to a struct and renders the **parsed**
values on the confirm card, so a misread "sell 100" shows as `SELL 100 AAPL`
before anything happens; the click spawns a separate one-shot run with literals
from the struct; a timeout reports `:unknown` and never auto-retries. That is a
better design than the roadmap's own Stage 2 items describe.

**But it states that order placement is unreachable.** `trading_order_confirm`
calls `TradingOrder.submit/1`, allowlisted for `place_equity_order`. A reader
would have concluded the opposite of the truth about real money.

**And the entire "direct broker progress" section describes code that is not in
the tree.** A first-party Robinhood MCP client, OAuth with PKCE, refresh-token
rotation, encrypted broker tokens, namespaced HMAC account keys — none of it
exists. The only OAuth in the codebase is Google's; the only HMAC use is webhook
signature verification; there are **42 `last4` references** and the app holds no
broker credentials at all. Stage 1's `[x]` for "introduce a stable opaque account
key" points at a boundary that was never built. Whether that work was descoped or
never landed is recorded nowhere — the roadmap simply asserted it, and it was
trusted for a week.

Both corrections are inlined **at the point of the claim**, and the archive header
says to read them before any checkbox. The `trading_tab` memory had the
architecture right the whole time; the roadmap was wrong.

What is genuinely still open moved to `LAUNCH_ROADMAP` **V.9**: a model still
transcribes `value`, `cash` and `buying_power` into the permanent ledger via
`Portfolio.Recorder`. The prompt is careful — *"copy each number from the named
field"*, *"never invent them"*, *"never clamp to zero"* — but careful prose is
not a parser, and Robinhood keeps no value history, so a number that lands wrong
is permanent.

## May the agent confirm a purchase? Yes, with the cost stated

The browser closeout existed for one design question, and it got answered:
**(b) a durable record** and **(B) the agent may confirm** — the second chosen
over the document's own (C) recommendation, with the cost on the table: a receipt
filed this way asserts a purchase no human affirmed, and a prompt-injected page
can reach the verb.

Every confirmation now appends one JSON object to
`browser-control/receipts.jsonl` — run id, cart, total, confirmation id, capture
path, timestamp — and `confirm_purchase/2` returns `recorded: true|false` so a
caller is never told a receipt was filed when the write failed.
`agent_run_confirm_purchase` ships at `:restricted`, answering the field test's
Finding 2: until now only the browse tab's form could call it, so an errand
driven from the terminal, from on-duty, or from a phone request could finish but
could never be receipted.

**(B) obliged something the roadmap did not ask for.** A receipt is no longer
self-evidently a person's word, so every receipt records `confirmed_by` —
`:human`, `:agent`, or `:unknown` for an unlabelled caller, which never silently
inherits a human's attestation. The record is honest about its own provenance
instead of pretending the question went away.

**A real bug fell out of building it.** `capture_confirmation/1` traps exits,
with a comment saying it exists so *"a post-payment engine death cannot also lose
the handoff confirmation."* The very next line — `AgentMode.complete/1` — was
untrapped. A CDP method that **raises** rather than returning an error killed the
run mid-capture and discarded the receipt for money that had already left:
precisely what the trap was written to prevent, one line further down. The
receipt is now built and written **first**; the mode transition is best-effort.

Both posture sites changed, not one — `introduction.ex` for the model and the
Explore tutorial for the user. Their tests failed on the old strings, which is
the lockstep working.

## Two mechanisms that existed and could not be reached

Part II items 2 and 4 turned out to be the same shape of defect.

**`find_elements` accepted a selector and dropped it** — in three places, not
one. The option never existed on `Page`, and both callers discarded their args.
The 07-25 field test passed `"input,form"` and `"#variation_size_name li"` and
got the same nav links both times.

The fix is not the one-liner it looks like. The moduledoc says `@enumerate_js` is
kept identical between `find_elements` and index targeting *so that an index
means the same element in both*, and `click index: n` resolves against the
**unfiltered** list. Filtering and renumbering would have returned indices
`click` could not honour — a quieter and worse bug than the one being fixed.
Indices are assigned from the full enumeration **before** the filter, and a test
asserts that ordering in the generated JS.

**Egress overrides had the mirror problem.** `Policy.level_for` has always taken
`:overrides`; `AgentMode` called `Egress.prepare` with no opts, so nothing could
ever feed it. The field test measured 89.8 KB leaving over 41 steps, every one at
`:full` with zero redactions — correct per the documented default, and it meant
complete Amazon pages including order history went to the model. Runs now freeze
per-host levels at start like the scope, `amazon.com` ships as `structure_only`,
and `browser_egress_level` reads and writes them.

The stored half lives in `Settings` and **the defaults live in code** — a direct
application of V.8, decided that morning: a seeded file could never be improved
on an install that already had one.

**One design correction mid-build.** The first cut read `Settings` inside
`AgentMode.init/1`, putting a database read in run startup. It broke every async
AgentMode test and would have meant a run that cannot boot when the repo is
unavailable. `AgentMode` reads nothing from the database and should not start
now, so the lookup moved to `agent_run_start`.

## The store behind `$secret`, and the invariant that matters more

Item 3 was held back deliberately as a posture question rather than a bug —
everything worked as designed and the "fix" removes a safety ceiling. **The
operator said yes: unattended runs may sign in.**

`SecretRef` has always been pure, correct and tested. What never existed was
anywhere to put a value, so the resolver defaulted to `fn _ -> :error end` and
every `$secret.<name>` failed.

**The store is the database, not a second Keychain integration**, which is the
one place this diverged from the roadmap's stated precedent. Values live in a
`browser_secrets` row typed `BusterClaw.Encrypted` — AES-256-GCM through `Vault`,
keyed from `secret_key_base`, which the Tauri shell **already** keeps in the
macOS Keychain and injects at boot. Following the precedent literally meant new
Rust commands, a new IPC surface, `build.rs` registration and ACL lockstep, for
no more protection than the existing one-key design gives — and that registration
is exactly what left the co-presence commands ACL-dead for weeks. `Encrypted`
also fails closed, so a rotated key makes a secret *unknown* rather than typing
ciphertext into a form.

The resolver is a function, not a snapshot: it reads on demand, so a secret
deleted mid-run stops resolving and no plaintext sits in run state.

**The invariant matters more than the feature.** `put` and `delete` are
`:restricted` **and gated**, so an untrusted agent's attempt to write or destroy
a credential surfaces for human approval. `list` is `:safe` and returns names and
notes only. **No command returns a value and there must never be one** — a test
asserts the absence of `browser_secret_{get,read,show}` so adding one fails there
first.

The **safe-tier snapshot test** caught the new `:safe` command and forced a
deliberate review before letting it through. That gate did exactly its job, and
the rationale now sits beside the list.

## G-40: one build, every answer

The closeout archived with one item unfinished — the live signed-in checkout walk
— and it moved to `LAUNCH_ROADMAP` **G-40** rather than dying with the document,
because it was never an item an agent could close.

G-40 is a consolidation, not just a new address. Every item that needed *a person
looking at a packaged build* had been accumulating separately: the checkout walk
in the closeout, the Chart Build look, the first-open workspace through the setup
wizard, and the packaged byte-range and codec walk in LEFTOVERS. They are one
sitting, not four errands, and splitting them across two documents is why none of
them had happened.

**The checkout walk leads it**, because three capabilities shipped today all
terminate at the same gate: the agent can file a purchase receipt, reach
signed-in sites unattended, and its egress on those sites is newly bounded but
unobserved. The gate between all of that and a live payment page is **tested and
never walked** — and the field test that started the roadmap found that exact
gate failing **open**.

## The cycle count went back up, and it was this morning's fault

The refactor roadmap took `mix xref` cycles from **6 → 2** on 08-02 and recorded
both survivors as accepted, noting that no `lib/buster_claw` file participates in
a cross-layer cycle. There were **3** today.

The new one is from this morning: `Trading → ChartBuilder → Portfolio → Trading`,
closed by the single `chat_opts_for("chartbuild")` line added with the Chart
Build tab. `Portfolio → Trading` already existed; naming `ChartBuilder` from
`Trading` completed the loop.

Fixed by extracting `BusterClaw.Trading.ChatProfile` as a leaf — the same
technique `AgentToolPolicy` and `AudioName` used. **A `defdelegate` from
`Trading` would not have worked**, and the first attempt made exactly that
mistake: the edge is the reference, not the call site.

**The real problem is that nothing was watching.** A structural result was
measured once, written down, and quietly undone a day later by an unrelated
feature; it surfaced only because someone re-ran `xref` by hand.
`scripts/check_cycles.sh` now asserts the **inventory** — the two accepted cycles
by name and by the reason each is accepted, anything else fails — and runs in
`mix precommit`. Breaking one of the two fails it too, deliberately, so the
roadmap gets updated in the commit that earns it.

The guard was **probed by reintroducing the actual cycle** and confirming it
fails, not by trusting that it would. That is this roadmap's own lesson: its
first README drift guard silently missed the line it was written for.

## What re-measuring the refactor roadmap found

It is **not** done, and its Progress section is not what says so — that section
is accurate about 08-02 and silent about four phases that were never begun.

`SoundStudioComponent` is **1,933** lines, exactly as recorded, untouched.
`StatusLive` is **1,420**, untouched. All of 3B/3C, all of Phase 4, Phase 0 items
8–9, UML sections 3–5, and the payload-key lockstep are unstarted.

**`TradingLive` grew back.** The 3,503 → 1,900 cut was real (−46%) and the
extraction held; the file is **2,174** today because Chart Build and the rest of
the week landed on top of it. Two data points together say something the first
one could not: this is a **rate, not a destination**. Either it gets re-cut
periodically or something has to make growth visible — the same lesson as the
cycle count, arriving twice in one day.

## Housekeeping

The stale `codebase_analysis` memory was deleted — it described the pre-rewrite
Go/Wails/SolidJS stack, which prompted the day's one purely factual question:
**no, there is no SolidJS in this app.** The frontend is Phoenix LiveView with
vanilla JS hooks; `assets/package.json` has exactly three dependencies, all
xterm. Every `solid` match in the tree is a CSS border, an icon name, or prose —
including the chart-builder rule written hours earlier saying gridlines are solid
hairlines.

Three roadmaps archived: Chart Builder, the Trading critical review, and the
browser closeout. `roadmaps/` is down to two live documents plus LEFTOVERS and
the launch map.

---

# Later the same day

> The opening line above says nine commits; the day closed at **fourteen** —
> thirteen here plus `076b263` from a second session working the same tree, and
> counting the summary commit itself. Left standing rather than corrected in
> place: what the day looked like from the middle of it is the record, and
> editing the count to match the ending would tidy away the honest version.

The morning archived three roadmaps. The afternoon went at the one nobody
believed was still open, and it turned out to be the day's fourth instance of
the same lesson.

## The code-quality roadmap is not done, and re-measuring found a regression

Asked to look at it on the assumption it was finished, and it is not: **its
Progress section is accurate about 08-02 and silent about four phases that were
never begun.** `SoundStudioComponent` was still 1,933 lines, exactly as recorded.
`StatusLive` 1,420. All of 3B/3C, Phase 4, Phase 0 items 8–9, UML 3–5 and the
payload-key lockstep untouched.

**And a result had silently come undone.** Cycles went 6 → 2 on 08-02 with the
note *"no `lib/buster_claw` file participates in any cross-layer cycle now."*
There were **3**. The new one was mine, from that morning:
`Trading → ChartBuilder → Portfolio → Trading`, closed by the single
`chat_opts_for("chartbuild")` line that shipped with the Chart Build tab.
`Portfolio → Trading` already existed; naming `ChartBuilder` from `Trading`
completed the loop.

Fixed by extracting `Trading.ChatProfile` as a leaf — the technique
`AgentToolPolicy` and `AudioName` already used. **A `defdelegate` from `Trading`
would not have worked**, and the first attempt made exactly that mistake: the
edge is the *reference*, not the call site.

**The real problem was that nothing was watching.** A structural result got
measured once, written down, and quietly undone a day later by an unrelated
feature; it surfaced only because someone re-ran `xref` by hand.
`scripts/check_cycles.sh` now asserts the **inventory** — both accepted cycles
by name and by the reason each is accepted, anything else fails — and runs in
`mix precommit`. Breaking one of the two fails it too, deliberately, so the
roadmap gets updated in the commit that earns it. Probed by reintroducing the
real cycle rather than trusting it, which is this roadmap's own lesson: its
first README drift guard silently missed the line it was written for.

## Reading the remaining work for whether we would defend it

Rather than working the list, the list got read. Three outcomes.

**3C is cut, by the document's own argument.** Its scorecard already records
Finding 4 as *"right diagnosis, wrong axis — sized by responsibility count, not
lines per responsibility"*, and 3C then listed five coherent mid-sized modules
on that wrong axis: `PortfolioChart` 996, `Commands.Web` 894, `CLI` 867,
`TerminalCommands` 795, `Gmail` 739. Splitting them buys smaller numbers and
more indirection, which the same document forbids two sections later. What would
put one back on the list is a *responsibility* count, and that is written down.

**The daisyUI contradiction is resolved by changing the rule, not the code.**
`AGENTS.md` forbade daisyUI outright while `app.css` imported the plugin, so the
rule described neither the code nor any destination anyone was walking toward.
It now states the convention actually in force: daisyUI supplies the primitives
and theme tokens, the `ic-` utilities and hand-written Tailwind carry the
Industrial Claw identity, and a stock daisyUI look never ships as the final
design. Migrating off the plugin was the alternative and was declined — a
UI-wide refactor whose only failure mode is visual, which no test can guard.

**Two items were kept because something written already existed and was simply
not protected or not run.**

## The bridge contract only checked half of itself

The Elixir↔JS lockstep has compared action *names* since 07-28. The roadmap
named the other half and nobody closed it: *"a rename of `wait_ms` on either
side is still silent."* It is silent in the worst way — the hook reads
`undefined`, the command runs, and the result looks like a page that simply did
not match.

Elixir now **declares** payload keys per action in `@payload_keys` rather than
the test inferring them from call sites. That mattered more than it sounds:
payloads are built in *both* `Commands.Web` and `Browser`, and a regex over
callers cannot tell a request key from a response key — an early attempt
produced a plausible-looking list containing `"matched"` and `"waited_ms"`.
`request/3` now refuses an undeclared key instead of letting it vanish, and the
lockstep compares the declaration against the hook's `payload.<key>` reads in
both directions. Probed by renaming `wait_ms` to `waitMs` and watching it fail.

## 22 tests that had never run anywhere

The `:browser_engine` tests drive a real Chromium over CDP. They appeared
**nowhere** in `.github/workflows` — excluded by tag since they were written and
collected by nothing. They pass: **22 tests, 0 failures, 58s** against local
Chrome, and again through the new `BUSTER_CLAW_BROWSER_BINARY` path.

They now have a scheduled lane, in **its own workflow file**. The first draft
added `schedule:` to `ci.yml`, which would have run the whole of CI daily while
carrying a comment claiming the opposite — caught by reading what the trigger
actually does rather than what the comment said. `Detect` only knows macOS
`.app` paths, so Linux pins the binary through `config/runtime.exs`,
deliberately outside the "guarded out of `:test`" rule because the tests that
need it run in `:test` and it only ever sets config when the variable is present.

## 3B, in two halves

**`StatusLive` 1,420 → 1,346**, and the line count is the least interesting part.

`Notifications.Schedule` took the timer/alarm/reminder wall-clock arithmetic,
which was pure the whole time and simply lived in a LiveView. That is *why* it
had no tests: asking "what does 11:30pm mean when it is 11:45pm" meant driving a
mount, an event and a form. `fire_at/3` now takes the clock, and 11 tests cover
what was never written — including `next_local_occurrence`'s real contract
(always ahead, never more than a day out) asserted as a property rather than by
pinning a timezone.

`track_end_ms` and `paste_track` existed **twice** — once in `StatusLive`, once
in `SoundStudioComponent`, in different shapes and unaware of each other. Two
implementations of *"where does this track end"* is one drifting apart later, on
a number that decides where audio lands. Both moved onto `StudioMix` with 9
tests neither copy had, including the one that catches the tempting wrong
version: it is the furthest clip **end**, not the furthest **start**.

**The rest of StatusLive's studio cluster was examined and deliberately left.**
`mutate_open_mix`, `step_history`, `push_studio_history` and `zoom_step` are
assigns plus `send_update` — undo/redo state a component cannot hold, because
the tab's `:if` discards it on every switch. Extracting them would move
orchestration into a module that then needs the socket passed to it:
indirection, not separation.

## The Studio template, decomposed

**`SoundStudioComponent` 1,926 → 1,250, and `render/1` 826 → 224.** It was 43%
of the module; it is 18% now. Five modules under `BusterClawWeb.SoundStudio.`:
`Format` (50), `Catalog` (46), `Sidebar` (202), `Overlays` (230), `Arranger`
(379).

**The order was the method rather than an accident.** `Format` first, because it
was called from ~25 sites and blocked nothing. Then the overlays, which read
three assigns between them. Then the sidebar. The arranger last: the most
entangled, and tractable only once `Catalog` existed to hold what it shared with
the component. Each extraction carried its own private helpers, because none of
them had a second caller.

**What the attrs bought is the actual product.** Reading `Arranger`'s nine
`attr` declarations now tells you what an arrangement is made of; the same
markup inside the old `render/1` told you nothing, because every assign in the
Studio was in scope. The line count is a side-effect of that, not the goal.

Two contract fixes fell out. `upload_error/2` takes the entry limit rather than
reading a module attribute, because a second copy of that number could disagree
with the `allow_upload` enforcing it. And `@max_import_entries` is exposed
through a function, because **`@name` inside `~H` is an assign and never a
module attribute** — a mistake that compiles.

## Two sessions, one working tree

The afternoon ran alongside another session rebuilding the Trading page's
research surface, and the tree showed it: `Research` deleted mid-compile while
`trading_live.ex` still called it, the build lock held by the other process,
`ChatProfile` — a module an hour old — rewritten by someone else to drop the
kind it had just been given.

Nothing was lost, and the reason is procedural rather than lucky. Work stayed on
files the other session was not touching; `git status` got read before every
stage; and the Studio commit went in with an **explicit pathspec**
(`git commit -- <paths>`), so it carried exactly seven files and left the other
session's staged work staged. The one honest caveat is recorded rather than
smoothed over: the gate ran against a tree holding both sets of changes, so it
verified mine-plus-theirs, not mine alone.

Their work landed as `076b263`: Chart Build absorbs data research, the Research
chat is deleted, `Research.load/search/blank` become `ChartBuilder.Fetch`, the
panel becomes `TradingLookupPanel`, and a migration retypes existing rows first —
because `Conversation.@kinds` validates by inclusion, so dropping the value
without one would have stranded every Research conversation.

## The day in one line

Four separate times, a written claim and the code it described had come apart —
a palette that failed its own checks, a roadmap saying orders could not be placed
while the button was wired, an OAuth subsystem described in detail that was never
in the tree, and a cycle count that drifted back within a day. None was caught by
reading. Every one was caught by running something. The two guards added today —
`check_cycles.sh` and the payload lockstep — exist so the next two are caught by
CI instead of by someone happening to look.

---

# The other session, same day: Chart Build gets the web

> This is the second session's account of the work the section above refers to as
> "their work landed as `076b263`". Six more commits followed it: `5792cac`,
> `50baa84`, `458ef24`, `88e48a0`, `5344c19`, `4b30ee6`. Written separately
> rather than merged into the account above, because two people describing the
> same afternoon from opposite ends of a shared tree is worth preserving as two
> accounts.

The brief was one sentence: Chart Build has no internet, and it needs to search
the web to build charts — plus, over time, a collection of good sources for free
financial data. Scoping it produced a rule the rest of the day hung off:

> **The model may look things up. It may not transcribe what it finds onto a
> chart.**

That is not fussiness. The renderer is freehand — the model emits SVG
coordinates and nothing checks the arithmetic, which is why every chart already
ships labelled *Drawn by AI · not computed*. That label honestly covers one
failure mode. A model reading numbers off a web page adds a second, independent
one, and the label does not cover it: two uncorrelated ways to be wrong, one
warning, on a picture of money. So search *informs*, and the app *supplies* —
plottable numbers come through our own fetch path with a source and an as-of
attached.

## The gate that changed the design before any of it was built

Phase 1 opened with a probe rather than code, on the theory that whether the
CLI's `WebFetch` can reach loopback is a question to measure. It can:

| target | result |
|---|---|
| `https://example.com` (control) | fetched fine |
| `127.0.0.1:4000` — BEAM listening | `read ECONNRESET` |
| `127.0.0.1:4999` — nothing listening | `connect ECONNREFUSED` |

Established-then-reset on one port and refused on the other is a pair only a host
that sees *this machine's* listening sockets produces. **`WebFetch` connects
locally**, which makes it an SSRF path into our own command API with `URLGuard`
nowhere in it. It is now denied to every profile; Chart Build ships with
`WebSearch` alone.

The near-miss is the part worth keeping. The only reason the probe got a reset
rather than our `/_health` JSON is that WebFetch force-upgrades `http` to
`https` while our endpoint is plain HTTP. Two implementation details happening to
line up — not a control. Serve TLS on loopback, or ship a CLI that drops the
upgrade, and the hole opens with nothing in this repository changing.

It also cost nothing: shipping search without fetch means the model sees snippets
rather than whole pages, and a snippet is a far weaker thing to transcribe a
series off. The security finding and the honesty risk had the same mitigation.

The same probe answered a smaller question nobody asked: `SlashCommand` in the
denial list *"matches no known tool"*. Kept anyway, with the finding in a
comment — a dead deny is free, a missing one is not, and a future CLI could
introduce it.

## FRED was the obvious first source, and its terms forbid us

A parallel agent verified eleven candidate APIs by calling them. The headline
was not a technical finding: **FRED's terms prohibit use "in connection with …
large language models" and prohibit "storing, caching, or archiving" its
content.** Phase 2 delivers observations into a Claude conversation; Phase 4
would persist them. Both clauses land squarely.

The route around it is that **FRED is a redistributor**. `CPIAUCSL` is BLS.
`GDP` is BEA. `DGS10` is the Fed Board's H.15. All three primaries are federal
works with no such restriction — so the first adapter became **BLS**, which also
happens to answer the roadmap's own acceptance test.

The operator closed it later: *drop it, we have reliable data*. Recorded as
**DROPPED BY OPERATOR DECISION**, not as an unread terms page, because those two
read very differently to whoever finds the entry next. One is settled; the other
is an invitation to go and check. (The page cannot be checked from here anyway —
it bot-blocks `curl` and WebFetch alike.)

## The fifth time a written claim and the code came apart

The day's through-line held. The BLS adapter passed 17 stubbed tests, so it got
run against the live API — and the keyless **v1 GET route silently ignores
`startyear`/`endyear`**. Asked for 2024–2025, it returned data through 2026-06: a
perfectly well-formed 200 for a window nobody requested, which on a charting
surface means the chart and its own subtitle disagree.

v1 POST honours the range keylessly (2022–2023 returns exactly 24 rows), so both
routes POST now. The structural fix matters more than the bug: every payload
carries `requested` and `covered` side by side, so a caller labelling a chart
from the span it *asked for* can no longer be wrong without noticing.

Three other traps came from the research and each got a test: `M13` is the annual
average and not a thirteenth month (plotted naively it is a phantom point at a
value no month had); failures arrive as **HTTP 200** with the verdict in the body,
which `Finnhub.get_json/3`'s status-only check would call success; and values are
strings where `"-"` means unpublished, dropped rather than defaulted to zero.

## The channel, and two brakes that were not in the scope

`datareq` mirrors the ` ```svg ` seam that already existed: the model emits a
fenced block, the app fetches through a real adapter, and the result returns as
the **next turn**. A turn specifically — `ensure_started/2` captures its options
once and the `--resume` session id dies with the process, so re-injecting any
other way would discard the conversation that just made the request.

Writing it surfaced a hazard the design had not named: **a `datareq` is a turn
that can provoke another `datareq`.** Hence a delivery budget of six, refilled
whenever the operator speaks — the risk is an *unwatched* loop, and a human
typing is precisely the end of unwatched, which makes that the honest reset
condition rather than an arbitrary timer. And a repeat brake: the same request
failing twice is refused a third time with an instruction to stop rather than
rephrase.

Malformed blocks cost no budget but are still answered, because a silently
dropped block deadlocks the conversation and a deadlocked model invents.

## Listing is not permission

The registry ships **in code** with workspace overrides merged at read time —
deliberately not a seeded file, because `maybe_write` never overwrites and a list
of third-party APIs is the most update-prone thing in the app. Sixteen sources,
nine `:verified`, and **exactly one fetchable**: a source needs `:verified`
status *and* an adapter. That gap is the whole design. It is what keeps a
`:blocked` FRED or an `:unsanctioned` Yahoo out of the fetch path even though
both are described in detail.

The rest are there so the *decision* is discoverable rather than the endpoint
being rediscovered — which is the entire reason to record a dead source at all.

Two existing guards earned their keep during this. `sources/` was already
declared `:deprecated`, and `sweep_deprecated/0` **deletes** an empty deprecated
directory — so the first operator to empty their override folder would have found
it gone. The registry's uniqueness test caught the collision. Then the safe-tier
snapshot refused `finance_sources` until it was reviewed by name, and caught the
follow-up mistake too: the review note went *inside* a `~w()` sigil, which has no
comment syntax, and the test reported 45 new "commands".

## What was verified, and what still has not been

Both model-facing halves were checked against a live run rather than assumed. The
Phase 1 gate — asked to chart CPI before the channel existed — refused, cited the
transcribe rule in its own words, and named series `CUUR0000SA0` from the BLS
monthly: exactly what `Finance.BLS.observations/2` takes, with neither side told
about the other. It also caught that portfolio history only reaches 2026-07-29,
applied the dual-axis honesty rule unprompted, and flagged a transfer as cash-in
rather than performance. After Phase 2 landed, it emitted a `datareq` block that
`DataReq.extract/1` parsed cleanly.

**Nobody has watched the whole thing run in the real app.** Request → delivery →
a drawn chart with BLS and an as-of in its subtitle: every piece is tested, the
composition is not. It joins the other Chart Build looking-at-it item in G-40.

Two more honest gaps. **BLS keyless is 25 queries/day** — a free key takes it to
500 and has not been registered, so "constant data" currently means a handful of
charts a day. And there is **no free keyless source of equity OHLC history**
anywhere in the registry, so *"chart AAPL over two years"* honestly answers "I
can't fetch that". Correct behaviour, but better known now than during a demo.

## The shared tree, from the other end

The mirror image of the account above. This session watched `sound_studio/`
appear mid-run and fail to compile, which made `mix test` impossible for a
stretch — so Phase 0 was verified in **an isolated `git worktree` at HEAD plus a
patch of only these changes**, rather than by touching anything of theirs. 2,279
tests, zero failures, against a tree containing one session's work and nobody
else's.

Later the contention moved to SQLite: two suites against one test database
produced 74 then 92 `Database busy` failures, every one of which passed when its
file was run alone. Waiting for the tree to go quiet gave 2,429 tests and zero
failures. Worth writing down because the failure count looked alarming and meant
nothing — and because the fix was patience, not a change.

Files were also edited underneath this session mid-work: an `ensure_dir` call and
an `{:unfetchable_source, key, status}` case that distinguishes "you misspelled
it" from "stop asking, and tell the operator why". Both improvements, both kept.

# Same day, third arc: the app learns to name its model — then its harness

## A flag that existed, was documented, and had never once been passed

`AgentRunner` has accepted `:model` and turned it into `--model` since it was
written. Nothing in `lib/` passed it. Every run — the homepage chat, a trading
read, an order submission, the dispatcher, a swarm — inherited whatever the
operator's `claude` CLI happened to be configured for, and the app had no opinion
at all.

That is the **third** mechanism this week that existed, was documented, and could
not be reached, after `Egress.prepare`'s `:overrides` and `secret_resolver`. The
pattern is now frequent enough to be a lesson rather than a coincidence: a
parameter with no caller is not a feature, it is a comment with a type signature.

`ModelPolicy` is the leaf every run site now asks — a global default plus
per-surface overrides — wired at all six. Unset means the flag is **omitted**,
not `--model ""`, so an install that upgrades into this behaves exactly as it did
the day before. Two tests hold that promise, one of which drives a real run
against a stand-in CLI and asserts `--model` is absent from the argv.

Built by eight agents in one workflow: four building disjoint file sets, one
running the suite alone (the shared SQLite database makes concurrent `mix test`
impossible), then three adversarial verifiers each trying to refute one property.
The wiring agent could not use `mix test` at all, so it rsynced the repo to a
scratch copy with its own database and probed there — including commenting out
each `model:` it had just added to confirm the test failed without it. That
instinct was better than the instruction it was given.

## The floor, and the measurement that earns it

`trading.ex` has recorded since 07-28 that haiku on a trading read invoked the
broker tool in only one run of two, and **on the miss it invented the answer**
rather than reporting a problem. A cheaper model on a money surface did not
fail — it fabricated.

That sentence has been a comment for a week. It is now a constraint: trading
reads and order submission carry a floor the global default cannot lower. Naming
that surface explicitly still goes below it, because the cost-saving gesture and
the money-touching consequence should not be the same gesture.

## Then the real question: which CLI?

"We need Codex and OpenCode too." Before answering, all three binaries were
probed with `--help` rather than recalled — and the roadmap written an hour
earlier was already wrong. It said `--model` was "claude-only **by
construction**". Codex has taken `-m, --model` all along; we simply never passed
one. That is the **sixth** time today a written claim and the tool disagreed, and
the only reason it was caught is that the tool was on the machine and got run.

The measurements are now a table in `AGENT_BACKEND_ROADMAP.md` and a leaf module,
`AgentBackend`, rather than prose. Three findings are encoded rather than
described:

**Codex refuses a non-repo working root.** `--skip-git-repo-check` is mandatory,
not defensive — the shipped workspace is not a git repository, so without it
every workspace run fails with a message that does not point at the fix.

**`bypassPermissions` deliberately does NOT become codex's `danger-full-access`.**
The literal translation is tempting and wrong: Claude's mode waives the approval
*prompt* while the tool allowlist still binds; codex's waives the *sandbox
itself*. Mapping one to the other would have silently escalated every headless
run the moment its backend changed.

**OpenCode fails OPEN, and this is the one that mattered.** A missing or misnamed
`--agent` file does not fail the run: it warns on stderr, falls back to the
default agent whose permission is `{*, allow, *}`, runs **unconfined**, and exits
0. Confinement that evaporates silently is worse than none, so the runner now
detects that line and refuses the result. Checking the exit status alone would
have accepted a completely unconfined run as a clean one.

## Harness first, then model — and why the storage keys on the pair

The operator's shape: pick `claude` → opus, `codex` → its own, `opencode` → glm
or kimi. Which forces a storage decision that looks like bookkeeping and is not.

A model ID is only meaningful inside its harness. Keyed by surface alone,
switching to codex for an hour would have **silently destroyed the entire claude
policy** — or, worse, shown a stale claude model as "in force" while codex ran.
Keyed on `{backend, surface}`, switching harness and switching back is lossless,
and a test says so. Rows written before harnesses existed migrate into the claude
bucket, floors included.

Only OpenCode can enumerate its own models (`opencode models` — 23 on this
machine, reflecting *this operator's* authenticated providers, so per-machine and
never shippable). Claude and Codex cannot enumerate at all, which is the argument
for keeping free text on every harness rather than a nicety.

## The floor is Claude-only, and now it admits it

The ranks are Claude model IDs and the 07-28 measurement was taken on Claude, so
the floor cannot be honestly enforced against kimi or glm. Left implicit it would
still "work" — an unranked model passes the comparison untouched — while *looking
like* protection that is not there.

The operator's call was to allow any harness on the money surfaces **provided the
warning is loud**. So `floor_applies?/2` and `unfloored_money_surfaces/0` make it
a state rather than an accident, and that state drives two warnings: one in
Settings, and one on the **order confirmation card** — because loud means at the
moment of the decision, not on a settings page visited days earlier. The card
resolves it itself so no call site can forget to pass it.

### And then the choice turned out not to exist

Both warnings were built. Neither will ever fire, and finding out why reversed
the decision the same day.

The money surfaces do not merely *prefer* claude — their Robinhood confinement is
written in claude's flag vocabulary (`--allowedTools`, `--disallowedTools`,
`--strict-mcp-config`, all three load-bearing per the probe at `trading.ex:290`),
and codex rejects it outright: `error: unexpected argument '--disallowedTools'`.
So a codex trading run does not run cheaply, and does not run unsafely. **It does
not run.** "Allow it with a loud warning" was a decision made before that was
known; kept afterwards, it would have offered the operator a choice whose only
possible outcome is a failed run, with a paragraph of prose explaining the risk of
something that cannot happen.

So `:trading_read` and `:order_submit` are **pinned** (`ModelPolicy.@claude_only`):
the Settings picker does not render for them, `put_backend/2` refuses them, and
`backend_for/1` answers claude whatever is stored. The operator's call was
reversed with the reason recorded at the pin — a capability fact outranks a
preference, and this one was discovered after the preference was expressed.

The two warnings stayed in the tree. `unfloored_money_surfaces/0` now returns an
always-empty list guarded by a test, and the order card's branch is unreachable
by construction — both kept as **live assertions** rather than dead code. Lift the
pin without a per-backend measurement behind it and they start speaking again, at
the two moments they were built to speak. That is the pin and the floor moving
together, which is the only way either is honest.

## Two bugs found by tests, both invisible to reading

`backend_for/1` matched the absent case with an `is_atom/1` guard. **`nil` is an
atom.** A surface with no override returned nil instead of falling through to the
global default — so per-surface overrides worked perfectly and the global default
never did once. Reading the function twice did not reveal it; the test did
immediately.

An unrecognised backend name reached `System.find_executable(nil)` and raised a
`FunctionClauseError` where it should have returned `{:error, {:agent_unavailable,
_}}`.

## Parsers written from captured output, not from imagination

`StreamEvent` was the shared parser for Claude's `stream-json` and nothing else,
so a codex or opencode chat would have streamed bytes nobody could read. Both
schemas were captured from the real CLIs using a **tool-using** prompt, because a
"say hi" run shows almost none of the vocabulary. Two facts only that run
revealed:

- OpenCode emits `step_finish` once per **step**, not per run; only
  `reason: "stop"` ends it. Treating every one as the end would have closed the
  transcript on the first tool the model used.
- Codex spells resume as a **subcommand** (`exec resume`), not a flag, so it
  cannot simply be appended. A codex conversation starts fresh each turn rather
  than being handed a flag codex would reject.

Anything not observed becomes `:unknown` with `raw` intact rather than guessed
at — a wrong mapping is worse than an ignored event, because the consumer renders
it. The tests paste the captured lines verbatim.

## A fix that made things eleven times worse, for a problem that did not exist

Worth recording in full because every step was reasonable and the whole thing was
wrong.

`model_policy_wiring_test.exs` appeared order-dependent: green at `--seed 0`,
seven failures at other seeds. The diagnosis was a read-modify-write in
`ModelPolicy.write/2` upgrading a SQLite lock — which `config/test.exs` explicitly
warns about. The fix was a transaction. It took the suite from **2 failures to 83**,
in modules that never touch `ModelPolicy`, because a transaction holds the write
lock on the single pooled connection and starves every other writer.

Reverted. And the flakiness it was meant to fix turned out to be **orphaned test
VMs from this session's own overlapping `mix test` runs** holding the database —
killing them made every seed pass. The lost-update race is real but narrow, so it
is now recorded in place with the fix that would actually work (compare-and-swap,
not a transaction) rather than papered over.

Two lessons, neither about SQLite: a failure count that varies run to run is
evidence about the *environment*, not the code; and a fix should be measured
against the same suite that motivated it.

## Two sessions, one working tree — the third and fourth invoice

The other session's account of this appears above. From this end it cost two more
things today.

`mix test` became unusable for stretches: 137 failures in one run, every one a
`Database busy` from a concurrent suite on the same SQLite file, none of them
real. Verification moved to an rsynced copy with its own database — the same
answer the workflow's wiring agent had already reached independently.

More expensively, **uncommitted work was discarded by a `git checkout` from the
other session**: the Settings harness picker and its five tests, gone, with no
stash to recover from. It was reapplied from the patch still in context, so
nothing was ultimately lost — but the lesson is to commit far more eagerly on a
shared tree than is otherwise sensible, and that "I'll commit when the phase is
done" is a bet on nobody else cleaning up.

## What is deliberately not done

The Sentinel audit trail does **not** record which harness ran a money surface.
Both UI warnings landed; this one did not, and it is the remaining item from the
floor problem rather than an oversight.

`opencode models` is not cached — the function documents that it shells out and
must not sit in a render path, and the Settings picker does not yet honour that.

And Phase 4 is deferred on purpose: **a per-backend floor must not be invented
before a per-backend measurement exists.** The 07-28 fabrication number is
Claude's and says nothing about kimi or glm. A floor built on a guessed ranking
would be worse than no floor, because it reads as protection. Cost reporting is
the happier half of that phase — and half a day was spent believing it was harder
than it is, which is the last thing worth recording here.

## The seventh time a written claim and the code came apart

"The CLI does not report spend back to us" was in both roadmaps, the Explore
tutorial and `AgentBackend`'s own descriptor (`reports_usage: :none`). It was
never true. Claude's `result` event carries `total_cost_usd`, `usage`, `num_turns`
and `modelUsage` — **measured today at `total_cost_usd = 0.0802325` on a one-word
prompt** — and `StreamEvent` has parsed that cost field the whole time. The app's
own parser contradicted the app's own documentation, which is how it was finally
noticed: not by re-reading the sentence, but by reading the code beside it.

Corrected in all five places. The bookkeeping shifts too — cost reporting is not
*cheaper on the new harnesses*, it is available on all three, in two shapes:
dollars from claude and OpenCode, tokens from codex. What is actually missing is
the aggregation, and the honesty problem inside it — this app owns no price table,
so converting codex's tokens to dollars would mean inventing a number the operator
would then trust. The remaining work is presentation, not capture.

One pattern, seven times now: a claim written once gets copied forward, and each
copy makes it look better attested rather than less. Both of today's harness
findings are the same shape — `--model` ("claude-only by construction", except
codex had taken it all along) and now this — and both cost one command to settle.
