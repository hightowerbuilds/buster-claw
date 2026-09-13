# Three doors — the first three fixes from the 09-13 UX review

**Scoped 09-13-26 · Status: BUILT 09-13, all three phases on main (`f666f06`,
`dfbb55f`, and the Phase 3 commit after them). Two of the three gates in Part IV
have NOT run: the Phase 1 real-CLI smoke and the Phase 3 dev-app walk need the
running app, and the Phase 2 walk needs a person with Google connected. See
Part IX.**

> ### The one-sentence version
>
> **Three small doors onto things that are already built: a brief so the home
> chat's agent knows what Buster Claw is, a control in the dock so a person can go
> on duty without a terminal, and a button in the browser toolbar so "ask about
> this page" happens on the page.**

> ### Where this comes from
>
> [`UX_REVIEW_09-13-26.md`](../UX_REVIEW_09-13-26.md) scored AI creativity 9/10
> and AI utilization 3/10, and traced most of the gap to one fact: the app's best
> briefing is addressed to the robot on a shift, never to the assistant in the
> chat window. Its fix list ranked ten items by leverage. **This map is items 1,
> 2 and 3.** Items 4 to 10 stay in the review until this ships.

> ### Read this before planning around it
>
> Every finding in Part I was read from source on 09-13 and re-verified by grep,
> not inferred. The three phases touch **disjoint files** (Part V lists them), so
> they can be built by three sessions at once, but only after Part II's decisions
> are read: two of them rule out the obvious implementation.

---

## Contents

- [Part I — What the code already tells us](#part-i--what-the-code-already-tells-us)
- [Part II — Locked decisions](#part-ii--locked-decisions)
- [Part III — The phases](#part-iii--the-phases)
- [Part IV — Gates](#part-iv--gates)
- [Part V — File scope, for parallel sessions](#part-v--file-scope-for-parallel-sessions)
- [Part VI — What this does not solve](#part-vi--what-this-does-not-solve)
- [Part VII — Risks](#part-vii--risks)
- [Part VIII — Open questions for the operator](#part-viii--open-questions-for-the-operator)

---

## Part I — What the code already tells us

### I.1 — The chat's brief is two paragraphs about drawing and audio

`lib/buster_claw_web/live/status/chat.ex:147` starts every conversation with
`SvgViewer.guide() <> "\n\n" <> Clips.guide()`. Together that is about 193 words.
Nothing names the CLI, the commands, or the workspace. The comment beside it
says why channels are taught: *"A model that knows neither has both capabilities
and uses neither."* The same sentence describes the other 190 commands.

### I.2 — The introduction exists, is 17k tokens, and no model has ever been sent it

`lib/buster_claw/introduction.ex` composes nine prose files plus a generated
command list into `.buster-claw/INTRODUCTION.md`, regenerated at boot and on
workspace switch. Size today: about 68 KB, roughly 17k tokens. `markdown/0` is
all-or-nothing; **there is no condensed accessor**. Its only reference outside
its own module is a terminal cheat-sheet prompt string
(`terminal_commands/builtins.ex:137`). `Introduction.read/0` has no production
caller.

### I.3 — The addendum is re-sent on every turn on the shipped transports

`ChatTransport` delivers `append_system_prompt` differently per backend:

| transport | how | cost |
|---|---|---|
| Claude one-shot (`chat_transport/claude.ex:81`) | `--append-system-prompt` argv, every turn | per turn |
| Codex one-shot (`codex.ex:80`) | prepended to the user prompt, every turn | per turn |
| OpenCode one-shot (`opencode.ex:83`) | prepended to the user prompt, every turn | per turn |
| ClaudeDuplex / CodexAppServer / OpenCodeServer | once per session (or per message for OpenCode) | behind `:chat_live_steering_enabled`, default false |

So inlining the introduction would cost ~17k tokens **per message** for every
shipped user, carried in argv on Claude. Nothing in the app caches a prompt
prefix. **That rules out the obvious fix.** See D1.

### I.4 — The chat already runs in the workspace root, and nothing is seeded there for the harness

`AgentRunner` defaults `cwd` to `Artifact.workspace_root()`
(`agent_runner.ex:96`), and the chat spawner uses it (`chat.ex:1485-1507`).
Claude Code reads `CLAUDE.md` from cwd; Codex and OpenCode read `AGENTS.md`.
`grep -rn "CLAUDE\.md\|AGENTS\.md" lib/ test/ docs/` returns nothing. The only
harness file seeded is `.claude/settings.json` with `bypassPermissions`
(`jobs.ex:206-213`). The workspace registry (`workspace.ex:53+`) and the
versioned writer `BusterClaw.Seed.write/3` (`seed.ex`) are exactly the mechanism
for a shipped, operator-editable, upgradable file at the root.

### I.5 — The Dispatcher's prompt is the model for a good brief

`dispatcher.ex:357-384` is ~190 words. It names the app, points at a file
(`Dispatch.md`) and the CLI, lists the three verbs that matter, states the
untrusted-data rule, and stops. It does **not** inline the surface. That is the
shape to copy.

### I.6 — `on-duty` is a shift start plus a poll loop that lives only in the escript

`cli.ex:252-277`: `on-duty` POSTs `shift_start` with `unattended: true`, then
`mailman_poll/1` loops in the **CLI process**, POSTing `gmail_sync` every 60s
(`cli.ex:396-421`). `gmail_sync` is what enqueues trusted-sender mail
(`google/gmail_sync.ex:186-201`). **There is no mail poller inside the BEAM.**
The Dispatcher only works what is already queued (`dispatcher.ex:138-174`).
An in-app "go on duty" that only starts a shift would start a shift that never
receives mail. See D4.

### I.7 — Nothing in the web layer starts a shift; `/duty` bounces when idle

No caller of `start_shift` under `lib/buster_claw_web`. `DutyLive.refresh/1`
(`duty_live.ex:50-67`) does `push_navigate(to: ~p"/")` when there is no active
shift. `DutyTabLive` + `duty_tab.js` inject an "On duty" tab only while active.
The wizard promises a *"Stand down button in the bar at the bottom of the
screen"* (`setup_live.ex:275`); no such control exists. The terminal cheat sheet
says *"Ctrl-C stands down"* (`builtins.ex:46`); `cli.ex:301-321` documents why
it cannot.

### I.8 — Stand down has two different meanings in the code

`Orchestration.stand_down/1` (`orchestration.ex:237-244`) engages the STOP file
**then** stops the shift. `Commands.shift_stop/1` (`commands/orchestration.ex:241`)
only stops the shift, so CLI `off-duty` does not latch STOP. DutyLive's button
uses `stand_down`. The dock control must too. See D6.

### I.9 — The dock has a documented rule about where live state may live

The app layout renders once and never diffs (`layouts.ex:264-268`,
`dock_nav_live.ex:8-20`); anything that changes must be a sticky `live_render`.
The right-hand group at `layouts.ex:281-285` holds `MusicPlayerLive` (which the
review found has no senders) and `DockLive`. `DockNavLive` deliberately does not
subscribe to anything; duty state must not be folded into it.

### I.10 — No cheap queue count exists

`dispatch.ex` has `list_queued/1`, `list_open/0` and one `Repo.exists?` probe.
A badge needs a new `Repo.aggregate(:count)` and recomputation on the three
dispatch broadcasts (`:dispatch_item_queued|updated|claimed`).

### I.11 — Readiness for a shift is checked in two places and trusted senders in neither

`Setup.status/0` checks workspace, tools, Google *connected*, went-live.
`DutyLive.email_ready?/1` (`duty_live.ex:69-71`) checks the stricter
`enabled and has_refresh_token and not reconnect_needed`. **Nothing checks that
`TrustedSenders.list_entries/0` is non-empty**, so a shift can start with an empty
allowlist and quietly never enqueue anything. The Manual calls trusted senders
*"the one thing you MUST configure."*

### I.12 — The browser chrome already has a door to the app, and it takes a query string

`chrome.js:275`: clicking an app-tab chip calls
`invoke("browser_app_navigate", {path})`. Rust (`browser/mod.rs:860-875`) checks
the path starts with `/` and evals `window.location.href = path` on the main
webview. **Query strings pass.** Everything the chrome knows about the active tab
(id, URL, title) is in its own tab model. This is the whole bridge; **no Rust
change and no ACL change is needed** for Phase 3.

### I.13 — Prefill exists and `StatusLive` ignores params

`bc:chat_prefill` (`status_live.ex:250-256`) switches to the Chat sub-tab and
pushes text into the composer **without sending**; `chat.js:31-36` receives it
even when the hook mounted in the same render. `StatusLive.mount/3` is
`mount(_params, ...)` with no `handle_params`. A `?ask=` param needs one new read.

### I.14 — The live-tab read path already works from Home

`browser_current` / `browser_read` go `Browser.Bridge` → `BrowserCaptureHook`
(on every LiveView) → `ScreenshotBridge` in the shell layout → Tauri. It runs
through the **shell**, not the browse tab, which is why the Explained tutorial's
"go to Home and ask what am I looking at" works today. Phase 3 adds a door, not
a path.

---

## Part II — Locked decisions

**D1 — The introduction is not inlined into the chat prompt.** 17k tokens per
message on the shipped transports is the reason (I.3). The brief is a
**seeded file** the harnesses read natively at zero per-turn cost, plus a
**one-paragraph pointer** in the addendum so a harness that skipped the file
still knows the CLI exists.

**D2 — One brief, two filenames.** `CLAUDE.md` and `AGENTS.md` at the workspace
root carry identical bytes, generated from one source. The app does not model
which harness reads which; it writes both. Both are `:core` registry entries
written by `Seed.write/3` so the operator may edit them and a shipped update
upgrades an unedited one.

**D3 — The brief points, it does not list.** Modelled on `work_prompt/2` (I.5):
what the app is, that `./buster-claw` is the hands, `./buster-claw commands` to
see the surface, the eight families a chat user actually reaches for (notes,
mail, calendar, library, browser, notify, memory, dispatch), the Activity-record
rule, the untrusted-data rule, and a pointer to `.buster-claw/INTRODUCTION.md`
for everything else. Target under 350 words. **It never lists commands**; the
catalog changes weekly and a list in a seeded file is drift by construction.

**D4 — Going on duty from the app starts a mail ticker inside the BEAM.**
A new supervised `BusterClaw.Mailman` GenServer, shaped like
`Telephony.Drain`: ticks every 60s, does nothing unless an **unattended shift is
active and the kill switch is clear**, and then calls the existing `gmail_sync`
for each healthy account. Gated off in tests like the Drain. The CLI's foreground
loop is **left alone in this map**; see VI and R2 for the double-poll question.

**D5 — The control lives in the dock's right-hand group, as its own sticky
LiveView.** `DutyDockLive`, placed left of the music player, subscribed to
`Orchestration` and `Dispatch`. Two states: **Off duty** with a "Go on duty"
button, and **On duty · N queued** with a pulse and a "Stand down" button. It is
a LiveView, not layout markup, for the reason in I.9.

**D6 — The dock's stand down is `Orchestration.stand_down/1`**, the one that
latches STOP first (I.8). Its caption is the Duty page's honest one: *"Stops new
work at once · a run in progress finishes."*

**D7 — The button refuses with a reason, never silently.** Disabled states name
the missing thing and link to it: no agent CLI → Settings → Configuration; no
healthy Google account → Settings → Configuration → Google; no trusted senders →
Home → Contacts. The trusted-senders check is new (I.11).

**D8 — `/duty` renders when idle.** The bounce-home is replaced by an idle state:
the same readiness cards, the trusted-sender count, and the same "Go on duty"
button as the dock. The injected top tab stays active-only; the dock chip links
to `/duty` in both states.

**D9 — "Ask about this page" is a URL handoff, prefill-only.** The chrome button
calls `browser_app_navigate` with `/?ask=page&url=…&title=…`. `StatusLive` reads
the params once, switches to Chat, and prefills a sentence that names the page
and asks the agent to read it with the browser commands. **It never submits.**
That is the Explained tab's "Try in Chat" contract and the review's best UX
decision; a button that sends on your behalf is a different feature.

**D10 — No Rust changes in this map.** Phase 3 rides the existing
`browser_app_navigate`. Keeping Rust untouched keeps the ACL lockstep test,
`build.rs` permissions, and the packaged-app smoke out of scope.

---

## Part III — The phases

### Phase 1 — Brief the chat

**Goal:** a fresh conversation, asked "what can you do here?", answers with
Buster Claw's actual capabilities and reaches for `./buster-claw`.

1. `Introduction.brief/0`: a new function returning the ~300-word brief (D3),
   with `{{WORKSPACE_ROOT}}` substituted. Source it from a tenth file,
   `introduction/00-brief.md`, so it is editable prose like the rest and
   `@external_resource` recompiles on change. **It is not part of `markdown/0`**;
   the full document stays as it is.
2. Workspace registry: two new `:core` `kind: :file` entries, `CLAUDE.md` and
   `AGENTS.md`, `seed: {Introduction, :ensure_briefs}`, written through
   `Seed.write/3` with a digest list, so the `SeedTest` pin catches an edit
   without a digest bump. Note in the entry that the bytes are identical and why.
3. `status/chat.ex:147`: the addendum becomes
   `Introduction.pointer() <> "\n\n" <> SvgViewer.guide() <> "\n\n" <> Clips.guide()`,
   where `pointer/0` is **one paragraph** (target 60 words): you are inside
   Buster Claw, the CLI is `./buster-claw`, read `CLAUDE.md` in this folder
   first. Under 100 tokens per turn.
4. Fix the comment that says the addendum teaches only channels.
5. Tests: `introduction_test.exs` gains brief content guards (names the CLI,
   names the introduction path, **contains no command names** so it cannot
   drift); `workspace_test`/`seed_test` cover the two entries and the identical-
   bytes claim; a new `status/chat` test asserts the composed addendum reaches
   `Chat.ensure_started` (today unasserted, I.1).
6. Note in the brief's file header that the Dispatcher's runs share this cwd and
   will read it too. The brief must not contradict `work_prompt/2`; it is
   generic on purpose.

**Existing conversations do not pick this up** until their Chat process restarts
(`chat.ex:361`, guides fixed at first start). A new conversation is the test.

### Phase 2 — Go on duty from the app

**Goal:** a person with Google connected and one trusted sender clicks one
control, emails themselves a task, and watches it get worked, without opening a
terminal.

1. `Dispatch.count_open/0` and `count_queued/0` via `Repo.aggregate` (I.10).
2. `BusterClaw.Mailman` (D4): supervised child gated by
   `:mailman_enabled` (false in test), tick 60s, guard = unattended shift active
   and STOP clear and at least one healthy account; work = `gmail_sync` per
   healthy account with the account's default query; failures logged, never
   raised; a `tick_now/1` for tests. Journals one line on first sync of a shift.
3. `Orchestration.ready_for_duty/0` returning `:ok | {:blocked, [reason]}` with
   the three checks (D7), using DutyLive's stricter email predicate moved into
   `Orchestration` or `Setup` so both surfaces share it (I.11).
4. `DutyDockLive` (D5, D6): sticky, `layout: false`, subscribes to Orchestration
   and Dispatch, renders off/on states, the count, and the button; blocked state
   renders the first reason as the button's caption with a link. Mounted in the
   right-hand dock group at `layouts.ex:281-285`, left of the music player.
5. `/duty` idle state (D8): remove the bounce, render readiness + trusted-sender
   count + the go-on-duty button; the active state is unchanged.
6. Copy fixes made true by this phase: `setup_live.ex:275` now describes the
   dock control (it becomes accurate rather than rewritten); `builtins.ex:46`
   "Ctrl-C stands down" corrected to match `cli.ex`.
7. Sentinel: going on duty from the dock observes a `:command_invoke` with
   `source: :dock`, matching what the CLI path already records.
8. Tests: `mailman_test.exs` drives `tick_now/1` with `gmail_sync` stubbed via
   the existing Google test seams; asserts no sync without a shift, none with
   STOP latched, one per healthy account otherwise. `duty_dock_live_test.exs`
   covers both states, the three blocked reasons, and that stand down latches
   STOP. `duty_live_test.exs` gains the idle render. `dispatch_test.exs` covers
   the counts.

### Phase 3 — Ask about this page

**Goal:** on any page in the in-app browser, one click lands you in Chat with a
question about that page ready to send.

1. `browser_chrome_controller.ex:290-305`: a new `button.bm#ask` labelled
   **Ask**, title *"Ask the assistant about this page"*, placed right of Pages.
   Hidden when the active tab is a private or agent-sandbox tab (the chrome knows
   `ephemeral`), because the assistant's read would be of a session that forgets.
2. `chrome.js:802-808`: `#ask` → `inv("browser_app_navigate", {path: "/?ask=page&url=" + enc(url) + "&title=" + enc(title)})`,
   URL and title read from the active tab's model, title capped at 200 chars.
3. `StatusLive`: a `handle_params/3` (D9) that, when `ask=page` and `url` parses
   as `http` or `https`, switches to Chat and pushes `bc:chat_prefill` with the
   sentence in step 4; any other value is a no-op. Params are read once; the
   sentence is capped at the existing 2000-byte prefill guard.
4. The prefill sentence, fixed text with two holes:
   *"I have **{title}** open in the browser ({url}). Read it with the browser
   commands and tell me what it says, then wait for what I want done with it."*
   The second clause is deliberate: it stops the agent from filing, capturing, or
   summarising into the Library unasked.
5. Tests: `browser_chrome_controller_test.exs` asserts the button markup;
   `status_live_test.exs` asserts `?ask=page&url=https://…` pushes
   `bc:chat_prefill` containing the URL and switches the sub-tab, and that a
   `javascript:` or bare-word `url` pushes nothing. `chrome.js` has no JS test
   today (I.12 report); the click is covered by the dev-app walk in Part IV.

---

## Part IV — Gates

Every phase: `mix precommit` exit 0, captured as `EXIT=$?`, number reported.

**Phase 1 — real-CLI smoke, dev only.** Open a *new* conversation, send
"What can you do in this app? List my notes." Pass = the agent invokes
`./buster-claw` (visible as a tool line) and names Buster Claw. Run once per
installed harness (claude at minimum). The 08-06 steering work found four defects
only the real-CLI smokes caught; a green suite is not this gate.

**Phase 2 — the operator's walk.** With Google connected and your own address
trusted: click Go on duty in the dock, email yourself "reply with the word
pineapple", watch the dock count go 1 → 0, receive the reply, click Stand down,
confirm `STOP` exists and the shift is stopped. Needs a person; an agent cannot
run it.

**Phase 3 — the dev-app walk.** In `cargo tauri dev`: open any article, click
Ask, land on Home → Chat with the sentence staged and **not sent**, press Enter,
see the co-presence pill fire in the browser chrome and the answer arrive. Then
repeat from a private tab and confirm the button is absent.

---

## Part V — File scope, for parallel sessions

Disjoint by construction. Each lane gets its own `MIX_TEST_PARTITION`.

| Phase | Writes |
|---|---|
| 1 | `lib/buster_claw/introduction.ex`, `introduction/00-brief.md`, `lib/buster_claw/workspace.ex` (two entries), `lib/buster_claw/seed.ex` (digest list only), `lib/buster_claw_web/live/status/chat.ex`, their tests |
| 2 | `lib/buster_claw/mailman.ex` (new), `lib/buster_claw/application.ex` (one child), `config/*.exs` (one flag), `lib/buster_claw/dispatch.ex` (two counts), `lib/buster_claw/orchestration.ex` (readiness), `lib/buster_claw_web/live/duty_dock_live.ex` (new), `duty_live.ex` + `.heex`, `layouts.ex` (one `live_render`), `setup_live.ex:275`, `terminal_commands/builtins.ex:46`, their tests |
| 3 | `lib/buster_claw_web/controllers/browser_chrome_controller.ex`, `assets/js/chrome.js`, `lib/buster_claw_web/live/status_live.ex` (one `handle_params`), their tests |

The one shared neighbourhood is `status_live.ex` (Phase 3) beside
`status/chat.ex` (Phase 1). Different files; stage explicit paths.

---

## Part VI — What this does not solve

- **The CLI's `on-duty` still runs its own poll loop.** After Phase 2 there are
  two pollers if someone uses both. Making `on-duty` a thin wrapper that starts
  the shift and tails the journal is the right end state and is a CLI change
  for a later map.
- **The chat still renders no markdown, shows no model name, and offers no
  suggested prompts.** Review items 5.
- **Agent Mode still has no button.** Phase 3 is the live-tab read, not the
  headful-Chromium errand.
- **The Manual is still unlinked, Calendar is still under Workspace, the Library
  still has no face.** Review items 4, 6.
- **The seeded brief does not teach skills or memory search in depth**, only
  that they exist; the full introduction remains the reference.

---

## Part VII — Risks

**R1 — A harness may not read the seeded file in headless mode.** Claude Code
loads `CLAUDE.md` from cwd for `-p` runs today; Codex and OpenCode read
`AGENTS.md`; none of that is asserted by any test here, and versions move. The
`pointer/0` paragraph in the addendum is the belt for that brace, and the
Phase 1 smoke is the only real check.

**R2 — Double polling.** If the CLI loop and the Mailman both run, `gmail_sync`
runs twice a minute. `Dispatch` enqueues by `dedupe_key`, so a message should not
queue twice; **verify that in the Mailman test** by syncing the same fixture
twice and asserting one item. If dedupe turns out to be by document rather than
by queue item, the Mailman must skip when a CLI poll ran inside the last
interval, which needs a last-synced stamp on the account.

**R3 — The brief is operator-editable and agent-reachable.** Anything in the
workspace already is. The brief carries no policy; policy stays in
`memory/policy.md`, which `Seed` deliberately does not touch. Do not put a
"deny" line in the brief and then trust it.

**R4 — `browser_app_navigate` is a full page load.** Phase 3 unloads whatever
LiveView was on the main webview. That is how every tab switch already works
(`tab_strip.js:174`), so it is the established pattern, not a new one.

**R5 — The chrome's tab model may be stale for the title.** Titles arrive via
`__onContentNavigated`; a page still loading may hand over an empty title. The
prefill sentence must read correctly with an empty title, so the template falls
back to the URL alone.

**R6 — A wrong readiness check blocks a working setup.** D7's three checks
could refuse someone whose Google token is fine but whose account row says
`reconnect_needed` from a stale sync. The blocked caption must say exactly which
check failed, so a false refusal is diagnosable in one glance.

---

## Part IX — What building it corrected (09-13)

Five things the map got wrong or did not know, each caught by a test or a gate
rather than by a person:

1. **The first brief named four commands that did not exist** (`gcal_list`,
   `document_list`, `document_read`, `notify_list`). D3 said "never list
   commands" and the draft listed them anyway. The brief now names families by
   prefix, and `introduction_test.exs` resolves every prefix against the
   catalog and refuses any bare verb the catalog lacks.
2. **D3 said the brief substitutes the workspace root. It must not.** A path
   inside the bytes makes the digest differ per machine, so `Seed` could never
   recognise a shipped version and every install would read as edited. The
   brief says "this folder"; a test refutes the placeholder and the home path.
3. **Phase 3's first cut used `handle_params/3`.** Home is also a child view
   inside a Split pane, and a child may not define it. Two SplitLive tests
   caught it; the param read lives in `mount/3`, which a child enters with
   `:not_mounted_at_router`.
4. **Two Studio tests were green for the wrong reason.** They asserted the
   word "Music" on `/studio`, which came from the deleted dock player, not the
   Studio's Material menu. They now seed a track first. A guard passing on a
   neighbour's output is the pattern the 08-09 dead-code pass wrote down.
5. **`chrome.js` is a FROZEN file and grew by 23 lines.** The cap was raised
   with the reason in the script; the extraction it owes is unchanged.

**Gates still owed** (Part IV): the Phase 1 smoke (a new conversation, "what
can you do here?", the agent reaches for `./buster-claw`), the Phase 3 walk in
`cargo tauri dev` (Ask → Home → sentence staged, not sent → pill fires), and the
Phase 2 operator walk (Go on duty → email yourself → count 1 → 0 → reply →
Stand down → `STOP` exists).

## Part VIII — Operator decisions (answered 09-13)

1. **The music player comes out of the dock in Phase 2.** The duty control
   takes its slot. The player's `live_render` and its `MusicPlayerLive` module
   go; the `/music/track/:name` route and `BusterClaw.Music` stay (the Studio's
   clip sources still read them). Adds `music_player_live.ex` and its test to
   Phase 2's file scope.
2. **Stand down from the dock is one click.** Stopping is the safe direction.
3. **The Ask button shows on `http://` pages.** The padlock already says the
   page is insecure; hiding the button would say nothing.
