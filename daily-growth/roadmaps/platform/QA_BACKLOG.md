# The QA backlog — real, and blocking nothing

**Carved out of the launch roadmap 2026-08-09 · Status: OPEN, unprioritised by design.**

> **Everything here blocks nothing.** That is the entry criterion. If an item
> blocks a release it belongs in [`RELEASE_GATE_ROADMAP`](RELEASE_GATE_ROADMAP.md)
> or [`APPLE_ROADMAP`](APPLE_ROADMAP.md); if it is a concrete deferred task tied
> to one surface it belongs in that surface's leftovers map. This is the middle
> tier: known QA debt, grouped by area, kept so it stays visible.

**Distinct from `LEFTOVERS`**, which holds *concrete* items someone could do
today. Several things here still need a design.

---

## Part V — The backlog

**Nothing here blocks the release.** It is kept in this document rather than a separate file
because the last time this work lived in its own roadmap, four documents disagreed with each
other and with the code. Promote items into Part IV when they earn it.

### V.1 — Testing gaps

The baseline is genuinely strong for a solo project: four CI jobs (`build`, `rust`, `js`,
`dialyzer`) plus the release DMG job, zero warnings, and a static ACL lockstep test that
catches a class of bug that only appears in the packaged app. The gaps are about *where the
confidence sits*, not volume.

> **Measured 2026-08-01: 2,028 tests, 0 failures, 22 excluded, 32.9s.** Up ~24% from the
> 07-27 measurement of 1,638. Green.
>
> **One thing observed and worth writing down.** An identical run launched *while a
> saturating Rust compile held the machine* produced **816 failures — every one of them at
> `Ecto.Adapters.SQL.Sandbox.start_owner!/2`, none in a test body.** Under CPU starvation the
> SQLite sandbox checkouts time out en masse. It is not a defect and the suite is not flaky
> on an idle machine, but **a loaded CI runner is the normal case, not the exception**, and
> this failure presents as 816 unrelated red tests rather than as "the machine was busy."
> If CI ever goes red that way, this is why. See **T-11**.

| # | Gap | Why it matters | Status |
|---|---|---|---|
| T-1 | No test proves the packaged app boots | BLOCKER-1 shipped through five green CI jobs | **Promoted → G-5** |
| T-2 | `:browser_engine` tests excluded by default **and in CI** | One of the largest subsystems; its tests never run automatically | Backlog — run nightly |
| T-3 | No exhaustive tier×command authorization matrix | The trust model is the differentiator; it deserves a generated test over the whole catalog | Backlog — *half a day* |
| T-4 | No end-to-end LiveView/browser tests | A stale-DOM defect on a deleted surface was invisible to server-rendered-HTML assertions — the class of bug outlived the surface | Backlog |
| T-5 | No migration test from a real 0.1.0 database | First update to a real user is the first time this runs | **Partly promoted → G-20** |
| T-6 | Smoke scripts manual, not in CI | Only checks that exercise production ACL resolution end to end | **Promoted → G-6** |
| T-7 | No soak/leak test | Always-on app, continuous render loops, long-lived LiveViews | Backlog |
| T-8 | No prompt-injection regression suite | The most likely real-world attack on an agent runtime | Backlog — **highest-value backlog item** |
| T-9 | Rust `browser/` modules thinly tested relative to size | 934-line `mod.rs`, 582-line `js.rs` | Backlog |
| T-11 | Sandbox checkout times out under CPU starvation | Green on an idle machine; 816 sandbox-checkout failures under a saturating parallel build. Presents as mass unrelated red, not as "the runner was busy" — and a gate that goes red for unreproducible reasons teaches you to ignore red | **New 08-01** — low priority, but pin `max_cases` or raise the ownership timeout before it bites in CI |

**Principles worth keeping.** *Test at the boundary that fails* — 131 passing tests on the
old Trading surface, concentrated on prompt text and pure math, missed a stale-DOM defect and
an unsafe execution boundary. The surface is gone; the lesson is not. And **every bug found in QA gets a regression test before the fix is merged**; the
QA lists are one-time discovery, the tests are what make them permanent.

### V.2 — Per-surface QA

Worth doing before a wide audience; not worth blocking the first download.

**Home** — chat send/stream/interrupt/error; a hung run is killed and reported · shader
degrades to blank canvas without an error · SVG sketchpad refuses malicious SVG (script tags,
external refs, `foreignObject`) · notify timer/alarm/reminder each fire and dismiss · journal
note survives restart.

**Terminal** — PTY survives tab switches and window resize · multiple terminals ·
close-with-busy-process confirmation · ANSI/unicode/wide-glyph rendering · large scrollback
doesn't wedge the UI · `./buster-claw` resolves inside the workspace on an installed build.

**Browser** — navigate/back/forward/reload/tabs/⌘1–9/⌘W/⌘F · tab eviction at the cap ·
popup-as-tab · download + reveal in Finder · bookmarks round-trip with folders · history dedup
and clear · agent co-presence badge fires on every agent-driven call · **SSRF guard refuses
`localhost`, `127.0.0.1`, `169.254.169.254`, an IPv6 literal, and a DNS-rebinding host** ·
Agent Mode run starts/streams/stops and survives the command call that started it.

**Workspace** — file tree lists/opens/renders markdown · drag-and-drop import · a file deleted
on disk disappears without an error · path traversal via a crafted filename is refused.

**Phone** — inbound call → greeting → record → transcript → Library doc + `/phone` row ·
voicemail audio plays · a call while the Mac is asleep drains on wake · inbound SMS from a
trusted number creates a Dispatch item, from a stranger archives only · outbound `sms_send`
respects the kill switch and daily cap · empty states read as "nothing yet," not broken.

**Calendar / Integrations / Security / Settings / Manual** — calendar handles all-day,
multi-day, and empty months · GitHub manual poll, good-signature webhook,
**bad-signature webhook must fail closed**, **no-configured-secret webhook must fail closed** ·
Security feed streams live, redacts secrets, paginates at 10k rows · every settings toggle
persists across restart · every Manual link resolves.

**Harness detection — the one check that can only pass in a packaged build.**
Added 08-15 from `DMG-review-8-15` findings 1 and 2, and it is here rather than
closed because **the fix is proven only in dev**. `ShellPath` resolves the
login-shell PATH so Settings stops reporting installed CLIs as missing, and its
30 tests replay launchd's environment with `env -i` — but a replay is not the
thing. In the signed app, confirm Settings → Configuration → Models lists the
harnesses you actually have, and that the "greyed out means not found" paragraph
does **not** appear when they are all present.

Two specifics a dev run cannot show. The flags are `["-lic", "-lc"]`, because a
zsh *login* shell does not source `.zshrc` — which on the dev machine is the
only file touching PATH, so `-lc` alone left codex undetected. A machine whose
profile is arranged differently is exactly what this needs to meet. And a
profile that prints on login welds its banner onto the value, so the PATH is
read from between fence markers; a shell that defeats the fence would show up as
a harness list that is wrong rather than empty.

**Studio → Voice (Ramshackle)** — added 08-14, operator's call, and it is **two walks that
must not be collapsed into one**. They fail in different places and a pass on either says
nothing about the other.

*The user's process* — open Voice, read the corpus counts, and check they match
`sound_gaps` run from the CLI on the same machine. Filter the vocabulary and confirm a word
you can see in the list is findable by a fragment of itself. Type a phrase mixing all three
verdicts and confirm the chips agree with what the corpus holds — **a single-take word must
read "quote only," never as cuttable**, because that distinction is the entire point of the
surface and it is the one a demo would quietly get wrong. Then leave the tab for Chat and come
back: **a half-typed sentence must survive the trip**, which is the `:if` state-lifetime rule
the whole surface was shaped around.

*The internal process* — the edits the engine makes that the UI never shows. Index a source,
correct a boundary by hand in the JSON, and confirm the corrected timing is what a later
`sound_sentence` cuts on. Confirm `origin` survives a round trip and that a damaged one
degrades to `aligned` rather than `manual` — the trust ceiling only holds if that degradation
is real in a packaged build, and it is asserted nowhere outside unit tests. Confirm a splice
written by `sound_assemble` lands in `sounds/studio/` and appears in Mix's source list without
a restart.

**In the packaged app specifically**, two things dev cannot answer: the corpus lives under the
configured DataZone rather than the workspace, so confirm Voice reads the *real* one and not
an empty dev path; and confirm the counts are non-zero, since **zero sources and a broken read
render almost identically** — the tab says "no indexed sources yet" for both.

**Recording is out of scope for this pass** and the tab says so on its face. When V.6–V.8
land, the level meter and the donor session get their own lines here.

### V.3 — The agent loop

`on-duty` → claimed → work → `dispatch reply` → `done` end to end · the STOP file halts an
unattended shift within one tick · the crash-loop brake trips instead of burning tokens · the
budget cap stops the shift and records a Sentinel event · killing the agent mid-run reclaims
the orphaned item · a wall-clock timeout kills the **whole process group** (no orphaned Bash
or MCP grandchildren) · `shift/Dispatch.md` matches the database after every state change ·
two agents cannot claim the same item · a malicious dispatch item body cannot escalate the
caller's trust tier.

### V.4 — Google Workspace

Connect/disconnect/reconnect; a revoked token surfaces a clear reconnect prompt · refresh-token
expiry produces a real message, not a silent failure · Gmail sync with 0, 1, and thousands of
messages · `gmail_send` from an `agent_untrusted` caller is refused and queued · attachments,
unicode subjects, HTML-only mail · a trusted sender's mail queues, a stranger's archives ·
Calendar/Drive/Docs/Contacts each survive an empty account and a rate-limited response.

### V.5 — Security and trust

**Tier matrix, exhaustively:** every catalog command against each of `trusted` /
`agent_untrusted` / `agent` / `mcp` — **automate this (T-3)** · a `restricted` command from
`mcp` is refused, recorded, and **not executed** · operator `policy.md` rules tighten but can
never loosen a baseline protection · Sentinel redaction catches an API key, a Bearer token, an
OAuth `code` in a URL, and a card number — **by key name *and* by value shape** · a phone PIN
never appears in `security_events` in the clear · CSP holds on every page · **prompt injection:
a hostile web page, a hostile email body, and a hostile SMS body each fail to make the agent
run a gated command.**

### V.6 — Durability, performance, accessibility

**Durability** — every migration runs forward on a 0.1.0-seeded database · kill the app
mid-write with no corruption or lost dispatch item · the workspace can be moved and found ·
deleting the workspace under a running app errors rather than crash-loops · a full-disk
condition is handled · encrypted secrets survive restart and a wrong key fails closed · SQLite
WAL files are checkpointed.

**Performance** — idle CPU with a continuous render loop · battery over an hour idle · memory
after 8 hours · per-row shaders under 100+ rows · cold start to interactive · a 10k-row
Security feed and 5k-item Dispatch queue still render.

**Accessibility** — full keyboard navigation · VoiceOver reads the audit feed and chat ·
contrast passes for hazard-orange on both backgrounds · gain/loss and success/refusal never
communicated by colour alone · `prefers-reduced-motion` disables the shader.

### V.7 — Platform matrix

| | Apple Silicon | Intel |
|---|---|---|
| **Oldest supported macOS** | determine (**G-16**) | determine (**G-16**) |
| **Current macOS** | required | required |
| **Latest beta macOS** | before each release | best effort |

Also: a non-admin user account, and a non-English locale with a non-US date format.

### V.8 — Seeded defaults have no upgrade path

**Status: open, needs a design. Inherited 08-03 from `CHART_BUILDER_ROADMAP.md`
(archived) — the operator flagged it as app-wide work coming soon.**

`maybe_write` — `File.exists?` → skip — is the house seeding idiom, and it is
used far more widely than the skill that surfaced it. Every one of these is
frozen at whatever version first touched that install; improving a default
reaches new installs only:

| Seeder | Files |
|---|---|
| `Skills.ensure/0` | `save-note`, `shader-designer`, roster |
| `Jobs.ensure/0` | `mail-triage`, `voicemail-triage`, `sms-triage`, roster |
| `Jobs.seed_trusted_senders/0` | **`memory/policy.md`**, `trusted-email-senders.md`, `trusted-phone-numbers.md` |
| `Jobs.seed_agent_settings/0` | agent settings |
| `TerminalCommands.ensure/0` | roster, command catalog |

**Note what is on that list.** `memory/policy.md` is the operator's security
policy, and `trusted-email-senders.md` / `trusted-phone-numbers.md` gate the
autonomous email and phone loops. If a *default* in any of those turns out to be
too permissive, **no shipped install ever receives the tightening.** That moves
this from a polish item to something V.5 has an interest in: it is the delivery
half of every default protection we ship. The command catalog has the same
shape — a newly gated command added to the default catalog does not reach an
install that already seeded one.

**Why this belongs in a release document even though it blocks nothing.**
III.I ships a patch channel for the *binary*. This is its content twin, and the
two have opposite defaults: code is replaced on update, workspace files never
are. So **whatever seeded defaults go out in R1 are what that cohort keeps
permanently**, and R1's cohort is the handful of people whose experience we most
want to be able to fix. The cost is asymmetric in time — cheap to design now,
and after R1 it means asking real users to delete files by hand.

**This is not hypothetical.** Caught 08-03 while reconciling the `chart-builder`
palette against the `dataviz` method: the shipped-by-default palette contained
colours that *failed* the OKLCH lightness band for a dark surface. Had that skill
gone out a day earlier, every install would have kept the failing palette
forever. The fix on this machine was `rm` on the dev-workspace copy — which is
exactly the manual step that does not scale past one machine.

**Why it is a design and not a chore.** Never overwriting is *correct* for
operator-edited files — file-first, git-diffable, operator-owned is the whole
point of the skills layer — and *wrong* for an untouched default. Those two
cases are currently indistinguishable, and that is the actual problem. The
design has to answer:

- How do you tell an operator's edit from an untouched default? Checksum the
  body we seeded, or carry a version in the frontmatter?
- Does an upgrade replace, merge, or write a `.new` beside the file and *say so*?
- Does a skill carry a version at all, and who bumps it?

**The one outcome worse than staleness is silently clobbering an operator's
edited file.** Design against that first — and note the security files raise the
stakes on the opposite side too: leaving a too-permissive `policy.md` in place
because the operator once touched it is its own failure. A baseline that
tightens may need to be enforced in code rather than seeded as text, which is a
real answer this design is allowed to reach.

Whatever the mechanism, apply it once across the whole table above rather than
per-seeder — six `ensure/0` functions drifting apart is how this became invisible
in the first place.

### V.9 — Trading: the model in the financial data path — **CLOSED BY DELETION 08-08**

**Was: open, needs a design.** Inherited 08-03 from
`TRADING_TAB_CRITICAL_REVIEW_ROADMAP.md` (archived); resolved by removing the
surface rather than by designing around it (`293f47f`).

Three findings were live when it closed, and they are worth keeping as a record of
what a money surface costs to hold — **not** as a to-do:

1. **A model transcribed money into the permanent ledger.** The account snapshot
   was a Claude turn emitting JSON, filed daily by `Portfolio.Recorder` into
   durable history. Careful prose is not a parser, and the broker keeps no value
   history, so a number that landed wrong was permanent.
2. **Submission travelled through a Claude run.** The struct was the source of
   truth and the operator had confirmed the parsed values, but the last hop was a
   model turn, and "do not double-submit" was prose rather than an idempotency
   guarantee.
3. **Last-four was the account identity, everywhere.** The archived review
   recorded a first-party MCP client with OAuth, PKCE and HMAC account keys as
   done. **None of it was ever in the code** — verified 08-03, and worth
   remembering as the sharpest instance of a checkbox outrunning a tree.

4. **Irreversibility asymmetry decided the design, and was noticed too late.** The
   ledger had to be durable because the broker published no history; the bar cache
   was disposable because a lost bar is one tool call away. **Which half a datum
   falls in should decide its schema before anything else does.**

**The generalisable lesson, which outlives the surface:** a checkbox in an
archived roadmap is a claim about the past, and the tree is the only authority on
the present. Finding #3 was found by grepping, not by reading the roadmap.

Full detail in `daily-growth/MM-DD-YY-Summary/08-08-26-summary.md`. The trading
sections of `archive/08-08-26-busterclaw-critical-review.md` were excised on 08-08 with the
surface itself; what they taught is recorded here.

---

### The Dock icon has never been seen to change — **packaged walk owed**

`APP_ICON_ROADMAP` shipped 08-15 with every layer tested except the one that
talks to macOS. `app_icon_set` has unit tests for path validation; **nothing has
watched a Dock tile change**, because there is no Dock in `mix test` and none in
a browser.

Three things are unproven, and the first is the one that would fail silently:

1. **That a Tauri sync command runs on the main thread.** `setApplicationIconImage:`
   is a plain AppKit UI mutation with no completion handler, so it must. The
   neighbouring `browser/ffi.rs` documents the *opposite* contract for its own
   calls, which is exactly what would talk someone into "fixing" this into an
   async command and breaking it.
2. That `NSImage initWithContentsOfFile:` reads what the operator dropped in.
3. That passing `nil` restores the bundle icon rather than clearing the tile.

**The walk:** drop a PNG into `pockets/app-icon/`, open Settings → Pockets, press
*Use this icon*, and look at the Dock. Then edit the file and confirm the shipped
icon returns. Then quit and confirm Finder still shows the original — that last
step is what proves the code signature was never touched.

---


---

## Finding index

The `F-n` numbering came from the 07-17 first-user review and is preserved so older notes
resolve. `G-n` items are the release gate, now spread across the maps in this folder,
`../website/` and `../distribution/` — each number still lives in exactly one map.

| # | Finding | Where it lives now |
|---|---|---|
| F-1 | Unsigned | **Written, unexercised** — III.0, G-1→G-4 |
| F-2 | Intel-only | ✅ **Two-arch CI built** — III.G |
| F-3 | Bundle waste (PLTs, Playwright) | ✅ fixed |
| F-4 | Bundle ID is a personal handle | ✅ fixed 07-18 |
| F-5, F-47 | No updater, no update notification | **G-18→G-20** — now P0 |
| F-6, F-17 | Wizard and README pitch different products | VI-a, **G-23** |
| F-7, F-53 | Homebrew assumed; "Re-check" has no failure detail | **G-10, G-11** |
| F-8 | "You'll do this once" vs 7-day beta tokens | Part VIII |
| F-9 | Max-permission onboarding in one click | VI-e |
| F-10, F-18 | Two agent entry points | VI.1 |
| F-11 | Unauthenticated loopback scopes · key reveal | **G-33** |
| F-12 | `Sentinel.Pending` is a stub with no gate | **G-29** |
| F-13, F-28 | README omits/misdescribes the home chat | VI-d |
| F-14, F-52 | `bypassPermissions` undisclosed | **G-31** |
| F-16 | Trusted-senders gate hidden in a corner widget | V.2 |
| F-19, F-25, F-26, F-27 | Documentation drift | VI-b, VI-c |
| F-20 | Phone in the dock, unbuilt for a new user | **G-37** |
| F-21 | Voice tab is a dead end | **G-36** |
| F-22, F-23, F-38 | Wallets over-built | ✅ removed `db10a58` |
| F-24, F-39 | Multiple independent shader systems | V.6, **G-17** |
| F-29, F-50, F-51 | Retired trial number; two live Supabase functions | ✅ fixed 07-18 |
| F-30, F-31 | Security buried; no refusal badge | **G-32** |
| F-32 | No kill-switch UI | **G-30** |
| F-33, F-46 | No agent-orientation check; empty first run | VI-f, VI-g |
| F-34 | `auth_status` dead signal | ✅ column dropped |
| F-41 | No telemetry or crash reporting | **G-25** |
| F-43 | No user-facing error recovery | **G-26** |
| F-44 | No workspace move/reset/export from the UI | V.6 |
| F-45 | macOS floor undetermined | **G-16** |
| F-48 | "Shipped = compiles" browser features | ✅ walked 07-22 |
| F-49 | Webview cache shared across builds | V.6 |
| **BLOCKER-1** | `build_desktop.sh` no longer stages the release | ✅ **fixed** — Part II |
