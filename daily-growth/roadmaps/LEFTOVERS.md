# Leftovers

Small, real, and deferred on purpose. Nothing here is blocking a ship; everything
here is the kind of item that quietly never gets done because it never becomes
urgent — until it does, at which point it is expensive.

The rule for this file: an item earns a line only if it is **concrete** (someone
could do it today without a design), and it carries **why it was deferred** and
**what makes it expensive later**. If an item needs a design, it belongs in a real
roadmap, not here.

---

## Open

<!-- DONE 07-22: "Walk the new automation primitives in the real app" — walked
against the PACKAGED app (stronger than the dev-shell ask). Agent side driven
via /api/run: wait (match + real 10s timeout), click text (matched_by:text +
navigation), extract selector+attr (30 matches), flow failing at the reported
step WITH screenshot on disk (twice), check_save→run→`## Runs` line, plus
open_tab (session:ephemeral honored), find_elements, read, screenshot (valid
PNG). Operator confirmed GUI side: co-presence badge flashed on every call,
7-tab eviction, sidebar bumper/⌘B, zoom, ⌘F count, popup-as-tab, download +
reveal, menu accelerators, and the double-launch single-instance check. -->

### Walk a live signed-in checkout and confirm the payment gate fires — **HIGH**

**What.** Browser-engine repair item 3, left PARTIAL on 07-25. After the
07-25 gate rewrite, Amazon's live entry point is confirmed gated and the
`/gp/buy/` funnel is confirmed gated *by test* — but never *by walk*, because
that funnel is only reachable from a logged-in session. Drive one real
Agent-Mode commerce run to a signed-in checkout and confirm the run halts.

**Why deferred.** Needs the operator's own signed-in Amazon session; nothing in
the repo can do it.

**What makes it expensive later.** This is the one item here that is
safety-adjacent rather than tidy. The field test found the gate failing OPEN on
exactly this funnel; the fix is tested but unwalked, and the cost of being wrong
is an agent proceeding through a real payment page. Cheap now, and the only way
to buy certainty.

---

### Give `find_elements` a real `selector` parameter

**What.** Browser-engine repair item 4. `page.ex:61` — `find_elements` has no
selector parameter, so callers filter client-side.

**Why deferred.** Low priority; the workaround costs a round trip, not
correctness.

**What makes it expensive later.** It doesn't — small, local, and additive.

---

### Keychain-backed `secret_resolver` wired into `agent_run_start`

**What.** Browser-engine repair item 5, in `commands/agent_runs.ex`. Secrets for
Agent-Mode fills currently resolve from the process environment; the design
calls for macOS Keychain.

**Why deferred.** Medium size, and the Egress `$secret.<name>` masking that
makes it safe already shipped — this is the storage half.

**What makes it expensive later.** The longer env-var resolution is the only
path, the more prompts and docs quietly assume it.

---

### Per-host egress levels with a config surface

**What.** Browser-engine repair item 6, `egress.ex:51` — per-host redaction
levels (e.g. `amazon.com` → `:structure_only`) exist in the code's shape but
have no operator-facing config.

**Why deferred.** Low priority; the global default is the safe one.

**What makes it expensive later.** Cheap to add whenever a host actually needs
a different level.

---

### Mirror input forwarding (click/type into the Agent Mode mirror)

**What.** The Phase 7 mirror renders a run's viewport as MJPEG but is
view-only. Forwarding input means mapping client coords → viewport coords via
the screencast metadata scale, then `Input.dispatchMouseEvent` /
`dispatchKeyEvent` over the CDP pipe we already own.

**Why deferred.** It is blocked on a real prerequisite, not on effort: the run
must carry an `awaiting_reason` so the mirror knows *when* human input is
legitimate. Taking the wheel at an arbitrary moment races the agent's own
actions. Inherited here 07-28 when BROWSER_ENGINE_ROADMAP closed, alongside its four
unfinished field-test repairs above. Everything in that roadmap's *Deferred*
list was ruled out on the merits; these five were not.

**What makes it expensive later.** Nothing structural — the transport and the
scale metadata already exist. It gets expensive only if `awaiting_reason` is
designed without this consumer in mind.

---

### Refresh out-of-repo prompts naming the old click/fill error atoms

**What.** `browser_click` / `browser_fill` fallbacks were renamed
`:missing_index` / `:missing_index_or_value` → `:missing_target` /
`:missing_target_or_value` on 07-18 (they can fail on more than an index now).
The repo is clean; anything *outside* it — saved prompts, agent skill docs,
personal notes — that names the old atoms should be updated.

**Why deferred.** Nothing in the repo can find or fix out-of-repo text.

**What makes it expensive later.** It doesn't get more expensive; it just
quietly misleads whoever reads that prompt next.

---

### Confirm the rotated DB password reached the password manager

**What.** The 07-18 Supabase rotation printed the new BusterClaw DB password
exactly once, in-session; it exists nowhere else. Confirm it's stored, then
delete this item. (The personal access token pasted that day needed no
revocation — 1-hour TTL, long expired.)

**Why deferred.** Only the operator can check their password manager.

**What makes it expensive later.** Nothing — nothing authenticates with the
DB password and a reset stays a two-minute dashboard job. Pure bookkeeping.

---

### Send `nosniff` on the four pipeline-less media routes — **HIGH**

**What.** Inherited 07-30 when `MUSIC_ROADMAP` was archived (its Part VII, the
only item that roadmap left open). `X-Content-Type-Options` appears **nowhere**
in the codebase. `RangeResponse` now sends it, which covers music and voicemail;
these four still serve workspace bytes without it, and — being intentionally
pipeline-less — without `put_secure_browser_headers` or **any CSP header**
either:

- `WorkspaceFileController` (`/ws/file`) — **start here; it renders workspace
  `.html` as-is**
- `NotifySoundController` (`/notify/sound`, `/notify/sound/:name`)
- `AppearanceController` (`/appearance/*` — user-uploaded images)
- `ShaderController` (`/shaders/:name` — user-authored WGSL)

**Why deferred.** It was found during the music build and belongs to the
security surface, not to a music roadmap. Nobody has owned it since.

**What makes it expensive later.** What these serve is a *workspace file* —
bytes a user uploaded or an agent wrote. Without `nosniff` a browser may sniff a
file named `.mp3` whose content is HTML, render it, and run its inline script
from our own origin, with no CSP on that response to stop it. That is the
`window.__TAURI__` → `terminal_*` → shell chain `ContentSecurityPolicy`'s
moduledoc exists to break, reached by a route that never gets the header. One
header each.

---

### Walk byte ranges and probe codecs in a packaged build

**What.** The two acceptance criteria `MUSIC_ROADMAP` could never close (Phases
1 and 2 of its risk list), inherited 07-30 on archive. In the **packaged** app,
not a browser tab: confirm `RangeResponse` satisfies WKWebView's media stack
(seek a long track, check duration reports), and confirm which of the six
accepted formats actually play — then shrink `Music.accepted_extensions/0` to
match.

**Why deferred.** Both need a packaged build, and the operator's walk. The unit
side is done: `RangeResponse` has 33 tests.

**What makes it expensive later.** This is the exact failure class the range
work existed to prevent — it looks correct in dev and misbehaves only in the
shipped webview. Shipping an accepted format that will not play is worse than
never having accepted it. Pair this with `SOUND_STUDIO_ROADMAP` Phase 5, which
needs a packaged walk for the same reason (autoplay posture, `afconvert` under
the sandbox) — one build, three answers.

---

## Rules of engagement

- An item leaves this file by being **done** or by being **promoted** to a real
  roadmap because it turned out to need a design. It does not leave by rotting.
- If an item has sat here through two dev summaries without moving, that is a
  signal it is either not actually worth doing (delete it, and say so) or it is
  more important than "leftover" implies (promote it).
