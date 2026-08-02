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

### Promoted 08-02 → `BROWSER_CLOSEOUT_ROADMAP.md`

Four browser items left this file together: the **signed-in checkout walk**
(HIGH), `find_elements`' **selector**, the **Keychain-backed `secret_resolver`**,
and **per-host egress levels**. They went to a real roadmap because the biggest
open browser question — *may the agent confirm a purchase, and what should a
confirmation even produce now that the wallets ledger is deleted?* — needs a
design, and this file's own rule says a thing needing a design does not belong
here. Their detail travelled with them; nothing was lost.

---

### Mirror input forwarding (click/type into the Agent Mode mirror)

**What.** The Phase 7 mirror renders a run's viewport as MJPEG but is
view-only. Forwarding input means mapping client coords → viewport coords via
the screencast metadata scale, then `Input.dispatchMouseEvent` /
`dispatchKeyEvent` over the CDP pipe we already own.

**Why deferred.** It is blocked on a real prerequisite, not on effort: the run
must carry an `awaiting_reason` so the mirror knows *when* human input is
legitimate. Taking the wheel at an arbitrary moment races the agent's own
actions. Inherited here 07-28 when BROWSER_ENGINE_ROADMAP closed, alongside its
four unfinished field-test repairs — which moved on to
`BROWSER_CLOSEOUT_ROADMAP.md` 08-02, leaving this one behind precisely because
it is the only one of the five that needs a *prerequisite* rather than a
decision. Everything in that roadmap's *Deferred* list was ruled out on the
merits; these five were not.

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

### Look at a first-open workspace through the setup wizard

**What.** Inherited 08-02 when `WORKSPACE_REVIEW_ROADMAP` was archived — the only
item it left open. Its Phase 5 count *was* measured against the packaged bundle
(fresh folder → **seven visible entries, all with content**), but by setting
`BUSTER_CLAW_WORKSPACE_ROOT` and listing the result. Do the same look the way a
new user gets there: packaged app → **setup wizard picks the folder** → open it
in **Finder** → count.

**Why deferred.** The scaffolding code is identical either way and is guarded by
24 tests; what's unverified is the wizard's own path into it (and how the folder
*reads* to a human, which is the thing no test asserts).

**What makes it expensive later.** It doesn't get expensive — it gets skipped.
This is the acceptance criterion the entire workspace rebuild was judged by, and
the roadmap's own Phase 5 note says we had never once looked at what we ship.
Pair it with the two packaged walks below: one build, three answers.

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
never having accepted it. Pair this with `SOUND_STUDIO_ROADMAP` Phase 5 and the
workspace first-open look above — one build, three answers.

> **08-01 update:** the packaged walk answered Sound Studio Phase 5's harder
> half — **`afconvert` executes under the sandbox; import works.** It also found
> what this item is about: a 20-minute file reported *length unknown*. Fixed
> (header-probe via `afinfo`, `eee2be3`). Still unwalked here: **seeking** a long
> track in the packaged webview, and the autoplay posture.

---

## Rules of engagement

- An item leaves this file by being **done** or by being **promoted** to a real
  roadmap because it turned out to need a design. It does not leave by rotting.
- If an item has sat here through two dev summaries without moving, that is a
  signal it is either not actually worth doing (delete it, and say so) or it is
  more important than "leftover" implies (promote it).
