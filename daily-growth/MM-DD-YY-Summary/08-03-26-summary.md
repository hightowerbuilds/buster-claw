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
