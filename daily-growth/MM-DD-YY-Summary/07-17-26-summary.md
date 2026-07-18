# 07-17-2026 Summary

Started as a one-fix day — the workspace desktop-drop from 07-15 didn't work in
the packaged app — then turned into a phone-tab pass: retired the rotary dial,
switched the Playback shader to mandelbrot, and built a per-voicemail Twilio cost
feature that, priced against the real data, upended the assumption that started
it.

## OS file drop: Tauri's native event, not HTML5 (`6438c55`)

The 07-15 version disabled Tauri's native drag-drop (`dragDropEnabled:false`) so
the browser DOM would receive the drop and a LiveView upload could consume it.
That trick is **Windows-only** — the tauri-utils source says so in as many words.
On macOS, WKWebView refuses to hand file *contents* to JavaScript on an OS drop,
so `dataTransfer.files` came back empty and nothing imported. The operator
restarted the shell (so the config change was live) and still saw nothing appear.

Reverted the config and switched to Tauri's native `tauri://drag-drop` event,
which delivers file **paths** rather than contents. The `WorkspaceDropzone` hook
now pushes the dropped paths to the server, and `FileManager.import_file` copies
each into the folder in view **by path** — efficient (no byte re-read) and the
correct primitive for local files. The HTML5 path stays only as a plain-browser
dev fallback; the two never both fire (native in Tauri, DOM in a browser).

**The symlink wrinkle, handled.** The operator's workspace root is a symlink to
a Desktop folder. Copying by path is exactly right for that: the OS follows the
link on write, and `FileManager.within?` already canonicalizes symlinks per
component so the containment guard still passes. `import_file` also learned to
copy a dropped **folder** recursively (`cp_r`). New tests cover the symlinked
destination and the folder-drop; operator-verified in the desktop app after a
restart.

**The lesson worth keeping:** Tauri's `dragDropEnabled:false` HTML5 route is
Windows-only. On macOS, use the native `tauri://drag-drop` event and copy by
path.

## Phone tab: rotary dial retired, Playback goes mandelbrot (`4a87206`)

Removed the decorative rotary dial (the SVG component, geometry, `dial_digit`/
`dial_clear` handlers, and the `RotaryDial` hook + `rotary_dial.js`). It looked
great but wrote a check the backend can't cash — it implied outbound calling
BusterPhone doesn't have. The Playback panel now rests on a plain "select a
message to play it here" placeholder. Same commit switches that panel's shader
from `waves` to `mandelbrot` (`shader_bg` took a shader name; only Playback
changed).

## Per-voicemail Twilio cost — and the number was a surprise (`4a59121`)

Built the whole cost path: `Telephony.Twilio` (a REST client shared with future
SMS) prices a voicemail from its RecordingSid alone — the Recording resource
hands back the parent `call_sid`, so no edge-function change or extra storage was
needed (I'd started down that road and reverted it). Cost sums recording + call
leg + transcription(s) into micro-USD; because Twilio prices populate
asynchronously, it's a retryable back-fill (`refresh_unpriced_costs`) riding the
drain tick, provisional until final. The `/phone` UI shows a per-message chip, a
call/rec/txt breakdown in the detail (sub-cent precision so the call leg reads
`$0.0085`, not a rounded `$0.01`), a running total, and a manual refresh. Creds
read from `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` in the Mac's gitignored
`.env`.

**The surprise:** priced live against all 8 real voicemails, each is **$0.0525**
— recording $0.0025 + transcription $0.05, with the inbound **call leg `null`**
(trial-credit calls never per-call price). So the motivating "20–30¢ per message"
was high by ~5×; the real per-message resource cost is a nickel, and
**transcription is 95% of it**. The one-line lever to cut it is dropping
`transcribe="true"` in the edge function (→ ~a quarter-cent). That null call leg
also caught a bug: it would have pinned trial rows "pricing…" forever and re-hit
Twilio every tick — so `final?` now gates on recording + transcription only.

## Wallets: the BusterClaw template

A wallet can now carry a **template** — a new select in the New Wallet form with
two options, `none` (an ordinary ledger) and `busterclaw` (a running-cost
tracker). The field is real end-to-end: a migration adds `template` (default
`none`) and a `model_costs` JSON map to `wallets`, the schema validates the
template value, and the command catalog exposes it on `wallet_create`/`_update`
so the agent can set it too.

A `busterclaw` wallet grows a **running-costs panel** with the two things it's
meant to surface:

- **BusterPhone** — the number and the running (lifetime) phone spend. The number
  isn't stored anywhere, so `Telephony.our_number/0` learns it from traffic (the
  `to_number` callers dialed on the most recent inbound event); the total comes
  from `Telephony.stats` in micro-USD, converted to cents. Both update live off
  the telephony PubSub topic.
- **Model subscriptions** — an inline editor for the monthly Anthropic / OpenAI /
  OpenCode bill, stored as a `%{provider => cents}` map on the wallet via
  `Wallets.set_model_costs/2` (written directly, never through the cast changeset,
  the same guard the cached `balance_cents` uses). Phone (lifetime) and model
  (monthly) figures are shown separately rather than summed — different periods.

## `data-confirm` never worked in the webview — now it does

Chasing "delete wallet doesn't work" turned up a class bug, not a wallet bug. The
backend deletes cleanly (FK cascade on, orphans zero); the failure was entirely
client-side. LiveView's `data-confirm` gates the event behind a **synchronous
`window.confirm()`**, and in the Tauri/WKWebView shell — no WKUIDelegate for
native JS dialogs — `confirm()` is a no-op that returns `false`, so LiveView
aborted every gated action. All **11** `data-confirm` sites were dead: delete
wallet/transaction/feed, delete/untrust contact, delete calendar event, the two
reset-commands buttons. Tests stayed green because `render_click` bypasses
`data-confirm` — the real app was broken while CI was clean.

The fix owns the dialog. `assets/js/lib/claw_confirm.js` installs a capture-phase
click interceptor (once, from `app.js`, like `installCaretKeys`): a control
carrying `data-claw-confirm="…"` gets its `phx-click` blocked, an Industrial Claw
modal shown, and — only on confirm — the click **re-dispatched** so LiveView
fires the event normally with all its `phx-value-*`/`phx-target` intact. A custom
modal is async and can't back LiveView's synchronous `data-confirm` (exactly why
the terminal-close case already rolls its own), so a global interceptor + a
`data-*` rename at each site beats adding `id`+`phx-hook` to eleven buttons. An
ExUnit source guard fails if any template reintroduces `data-confirm=`.

## Notify — a widget the model can ring from anywhere (Phases 0–3)

A new homepage widget: BusterClaw can set timers, alarms, and reminders, and when
the moment comes it rings a modal. Built in four phases, each committed and green.

**The design insight that made "from any point of entry" cheap:** chat, terminal,
and dispatched email/voicemail already converge on one surface — the command
catalog. So the whole cross-channel story is a single `notify_*` command domain;
no per-channel wiring. `notify_create` (`:restricted`, so untrusted-origin content
can't plant an alarm) is reachable from every trusted caller.

- **Phase 0 — spine (`e215d06`).** `notifications` table + context (absolute
  `fire_at`, so a timer is now+duration at create time and alarms survive a
  restart); a supervised `Scheduler` that arms a single timer to the earliest
  `fire_at` (capped so drift self-heals), re-arms on changes, and broadcasts
  `{:notification_fired, _}`; the `notify_*` command surface.
- **Phase 1 — the widget tab (`da6c10b`).** A fourth corner-widget tab: quick-add
  (label + minutes → timer), a live list of everything armed, snooze/dismiss,
  refreshing off the `"notifications"` topic.
- **Phase 2 — the shader digits (`24ab5bd`).** `sevenseg.wgsl.js` draws `DD:DD`
  from remaining seconds on the prelude's free lens channel; the `ShaderTimer`
  hook owns the tick locally (smooth, no round-trips) and falls back to a text
  `MM:SS` node when WebGPU is missing. The soonest notification shows as a big
  segment countdown atop the tab.
- **Phase 3 — the modal (`ab910dd`).** The fired broadcast pops a modal — label
  over a `00:00` segment display, Snooze 5m / Dismiss — reusing the shader.
- **Phase 4 — app-wide (`3e3b432`).** The modal now surfaces on any page, not just
  the homepage, via a tiny `NotifyLive` mounted `sticky: true` in the root layout
  (its own process, its own subscription). A separate process rather than an
  `on_mount` hook because 10 of the page LiveViews have no catch-all
  `handle_info`, so letting `{:notification_fired, _}` propagate would crash them.

**Not yet verified / done:** the WGSL has only run in CI's absence — worth an
eyeball in the real webview (the text fallback keeps a misrender from breaking
anything), as is confirming the sticky modal actually pops while on a non-homepage
tab. A **native OS notification** (fires while the app is unfocused) is the
remaining Phase 4 piece.

## State of the tree (pre-quality-pass)

`mix precommit` green — **1059 tests**, 0 failures. Seven commits on main today: the
BusterClaw wallet template, the webview confirm fix, and the five Notify phases
(0–4) — on top of the morning's four. `.env` holds the Twilio creds and stays
untracked. Follow-ups worth doing: fold `tab_strip.js`'s busy-terminal modal onto
the shared `clawConfirm` helper, and Notify's native OS notification.

## Evening: whole-codebase quality pass (6 commits)

Post-build-streak review — four parallel audits (dead/orphaned, suppressed,
frontend/Tauri, performance) over the whole repo, then the fixes. The audits'
headline: the codebase was far cleaner than a build streak usually leaves it
(zero warnings, zero skipped tests, zero TODOs, zero commented-out code; every
feature cut was executed at the root). Plan + full findings live in
`daily-growth/roadmaps/CODE_QUALITY_ROADMAP.md`, including every deliberate
skip with its rationale. Standing constraint: **no visible UI changes** — every
fix is backend-invisible or pixel-identical.

- **Telephony broadcast storm (`ff3a564`).** The drain tick prices up to 25
  voicemails and broadcast once per row → 25 full re-queries + re-diffs per tick
  in every subscribed LiveView. Now one batched `:telephony_costs_updated` per
  pass, and `PhoneLive` coalesces bursts behind a 250ms timer.
- **Contacts triple-load (`e376a0a`).** `PhoneLive.load_contacts` hit the
  contacts table three times per broadcast; `by_phone/1` and `orphan_entries/1`
  now derive from the one loaded list.
- **AudioClip loops parked off-screen.** Every voicemail row ran a perpetual
  60fps WebGPU shimmer loop — 200 rows, 200 loops. An `IntersectionObserver`
  now runs only the clips actually in the viewport; visible clips render
  exactly as before.
- **Silent failures now log.** The big one: `drain.ex`/`gmail_sync.ex` discarded
  `Dispatch.enqueue` results — a trusted voicemail/email could silently never
  become agent work. Real failures log; dedupe re-sync conflicts stay quiet.
  Also: introduction install, workspace-config write (Rust), and the
  screenshot/command/download/history report drops (JS + Rust).
- **Dead code deleted.** The Whisper STT permission cluster in the Tauri shell
  (capability grants + two autogenerated tomls, removed as an atomic set, cargo
  check green) and the no-op `DNSCluster` child + dep.
- **Chat transcript → LiveView stream.** Appends send one bubble instead of
  re-rendering the capped 200-message list; DOM ids unchanged via
  `stream_configure`; empty state via the CSS `only:` idiom; `data-seq` keeps
  the scroll hook firing. Phone log / wallet ledger / SVG rail deliberately NOT
  converted (full-requery surfaces with server-side reads — rationale in the
  roadmap).
- **Poll ticks parallelized.** Wallets feed polls and Twilio cost back-fills
  fetch concurrently (`Task.async_stream`, 15s hard timeout) so one hung
  endpoint can't stall the GenServer tick; DB writes stay on the caller
  (SQLite single-writer). Plus prepend/reverse in `load_chat_history` and a
  zero-allocation smoke-shader frame loop.

**State of the tree:** `mix precommit` green — **1061 tests**, 0 failures.
The untracked Notify debugging repro
(`test/buster_claw/notifications/repeat_repro_test.exs`) was deleted by
operator call. Note `scheduler_test.exs` covers fires-when-due and
stays-armed-when-future, but not the repro's exactly-once-across-rapid-ticks
assertion — if that guarantee matters, it deserves a real test someday.
Working tree clean.

## Night: the first-look reviews, then the Notify sound board

### Three distribute-today reviews land in roadmaps (`6ae70ba`)

Seven parallel reviewers walked the new-customer journey — install/first-run,
home chat, GWS/on-duty, BusterPhone, browser/terminal/library, settings/
security, product gaps vs. the other claws — and the synthesis is
`roadmaps/FIRST_LOOK_CRITICAL_REVIEW.md` (~7,100 words, severity-tiered, with
a punch list). Committed alongside the two companion docs from the same pass
(`CUSTOMER_FIRST_LOOK_REVIEW.md`, `FIRST_USER_REVIEW_ROADMAP.md`); all three
also copied into the DataZone. The recurring pattern: **the interior is better
than the entrance** — the ship-blockers are the unsigned Intel-only DMG, the
silent chat failure when Claude Code isn't logged in, the tester-list OAuth
gate, the unconfigurable/unpurchasable phone tab, and the missing
single-instance guard.

### Notify sound board: per-event routing (`a1eb389`)

The DataZone `sounds/` folder now holds real audio — `wilhelm.wav` (the
Wilhelm scream) and `bongos.wav`, both CC0 from Wikimedia Commons, normalized
and trimmed with ffmpeg, plus a synthesized neutral `notify.wav` default and a
provenance README. On top of it, `Notifications.Sound` grew from
single-chime resolution into a routable library: a JSON map in Settings keys
sounds by **source** (chat/terminal/email/voicemail/manual), **kind**
(timer/alarm/reminder), or default — source beats kind beats default, floor is
the legacy `notify.*`/first-file walk. `/notify/sound/:name` serves only real
directory entries (membership in `list/0` is the allowlist — no traversal
surface), and the `NotifySound` hook swaps `src` on its one gesture-unlocked
audio element so per-event sounds don't lose playback permission.

The new **Settings → Notify** tab is a control surface, not an explainer (the
Voice-tab mistake, not repeated): a routing grid with an honest "plays: X"
readout per row, client-side Preview, a **Test** button that fires a real
notification through the full pipeline (scheduler → modal → routed sound),
and library management — upload with a server-side extension gate,
delete prunes routings. One catch en route: the repo's own guard test
rejected `data-confirm` (a no-op in the webview — the exact hole the browser
review documented) and forced `data-claw-confirm`.

### The widget learns all three kinds (`44e00f1`)

The corner widget's Notify form was timer-only; now a segmented
Timer | Alarm | Reminder row picks what gets armed. Timer stays
label + minutes. Alarm is a wall-clock `<input type="time">` with the label
**optional** (blank → "Alarm"). Reminder — after an operator course-correct
away from the command surface's fire-now semantics — is label + a scheduled
announcement time. Both wall-clock kinds arm the **next local occurrence**
(OS-clock offset rounded to 15-minute granularity, no tz database; an alarm
set across a DST flip lands an hour off — documented, accepted). The kind row
also **filters the right column**: the seven-segment hero re-keys to the
soonest of the selected kind and the list shows only that kind, with per-kind
empty states. Form type settled at 13px inputs / 11px controls after one
too-small → too-big → just-right iteration.

**Open from the widget review** (deliberately not fixed tonight): Snooze on an
*upcoming* row re-arms to now+5m — pulling a 45-minute timer to 5 minutes;
ShaderTimer only pauses on `document.hidden`, so hidden-tab heroes burn a
60fps WebGPU loop; `notify_modal`'s doc comment still credits StatusLive for
what NotifyLive now does.

**State of the tree:** full suite green — **1090 tests**, 0 failures.
Working tree clean after this summary commit; pushed to main.

---

## Night session: the browser leg of the first-look review

Operator call: park the review findings we can't act on yet (Apple signing,
Google verification, BusterPhone's missing door) and work the browser section,
which is entirely in our hands. Four review items went in — and the
investigation surfaced a fifth thing nobody knew was broken.

### Co-presence was ACL-dead the whole time (`a6668a1`)

The review's §5.3 credits "the agent genuinely drives the live browser" as a
strength. Statically, it couldn't have: `browser_current`, all six `*_active`
co-presence verbs, and `terminal_busy` were in `generate_handler` but **never
in `build.rs`'s AppManifest or any capability file** — and on Tauri 2.11.1
the ACL denies unregistered commands before they reach Rust. Every
`browser_read`/`browser_click` from the agent has failed at the ACL since
Phase 3 shipped. The bitter part: `build.rs`'s own comment documents this
exact failure mode, and the browser-roadmap memory records the
"three registrations" rule — the Phase 3 commit just didn't follow it.
Registered everything, verified the resolved ACL in `gen/schemas` carries all
the allows. Memory corrected so "shipped" claims about Tauri-invoked features
get checked against the registration triple.

### The packaged app learns to read SPAs (`f963963`)

The review's sharpest browser finding: prod has no Playwright sidecar, so
`browser_fetch` falls back to plain HTTP and modern JS-rendered pages come
back as garbage — while the same URL renders fine in the visible tab. The fix
rides the machinery we already ship: a new `browser_render_page` Tauri command
loads the URL in a **hidden, off-screen, ephemeral** webview (incognito data
store — never the user's session), waits for `readyState: complete` plus a
hydration settle, runs the same read script `browser_read` uses, and closes
it. `Browser.fetch` upgrades to it automatically when the classic pipeline
comes back JS-thin (<280 chars of readable text) **or fails outright** — a
real WebKit view walks past the bot-wall 403s that stonewall a bare HTTP
client. The Bridge grew subscriber tracking (`available?/0`) so CLI-only use
skips the fallback instantly instead of eating a timeout, plus per-request
`timeout_ms` for load-sized budgets. Live-rendered pages are marked
`via: live_render` on the Sentinel feed — the audit trail says which engine
executed the content.

Same commit, two smaller review items: **evicted tabs keep their scroll** —
an injected shim (popup-shim pattern) debounce-saves scroll per URL into
origin-scoped localStorage (LRU-capped, 6h TTL) and restores on the
switch-back reload, skipping anchor URLs and self-restoring sites; form input
stays unrecoverable, deliberately. And **find-in-page shows "17 matches"** —
`browser_find_count` counts occurrences in rendered `innerText` via
`eval_with_result`; not positional "3 of 17" (that needs the native find
API), but no more flying blind.

### Favicons and honest search errors (`ff4197c`)

Favicon fetch only ever tried `/favicon.ico`; on a miss it now reads the site
root and follows `<link rel="icon">` (plain `icon` beats apple-touch, `data:`
skipped, resolved URL re-vetted by URLGuard so a hostile page can't aim the
fetcher at metadata addresses). And DDG search stops returning `{:ok, []}`
for every zero-parse: a genuine no-results page stays empty, a challenge page
is `:blocked_by_provider`, changed markup is `:scrape_failed` — breakage
stops masquerading as "no results", which was one of the review's recurring
silent-failure patterns.

### The docs-drift gate had been dead too (`b8f0f8c`)

Running the gate against the catalog change revealed it exits 1 with **zero
output** — and does on clean HEAD too. The CLI dispatch moved from
`case args do` to `route/2` function heads at some point; the gate's sed
matched nothing, `set -e` killed it at the empty VERBS assignment, and the
guard built to stop silent rot rotted silently. Reparsed from the route
heads, added a loud fail-on-empty guard. No actual drift had accumulated —
lucky.

**Deliberately not touched:** the WKUIDelegate ceiling (accepted 07-04 —
`window.confirm` in content tabs rides with it; a sync shim can't fake a
blocking dialog) and the Playwright sidecar prune (parked, operator call).

**Verification honesty:** the fallback logic is exercised in tests with a
fake desktop fulfilling bridge requests; Rust compiles clean; bundles build.
But the end-to-end paths — ACL-unblocked co-presence, the hidden render,
scroll restore, the find count — need a live app run: `./scripts/dev.sh`,
then `browser_read` a page, `browser_fetch` a React docs page, open 7+ tabs
and switch back to the first, ⌘F something.

**State of the tree:** full suite green — **1104 tests**, 0 failures; 78 JS
tests green; `cargo check` clean; credo strict clean; drift gate green.
Working tree clean after this summary commit; pushed to main.
