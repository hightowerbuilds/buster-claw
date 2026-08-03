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

### Promoted 08-03 → `LAUNCH_ROADMAP.md` **G-40**

Every item that needed *a person looking at a packaged build* left this file
together and became one release gate: the **Chart Build look**, the
**first-open workspace through the setup wizard**, and the **packaged byte-range
and codec walk** — joined there by the **signed-in checkout walk** inherited
from `BROWSER_CLOSEOUT_ROADMAP.md` on its archive.

They went because they are one sitting, not four errands, and because splitting
them across two documents is why none of them had happened. The detail travelled
with them; nothing was lost. This file's rule still holds — they needed no
design, only a build and an afternoon — but they blocked a release, and this
file is explicitly for things that block nothing.

---

### The `sound` command surface — the Studio has no CLI

**What.** Inherited 08-02 when `SOUND_STUDIO_ROADMAP` was archived (its Phase 2,
never built). New `commands/catalog/sound.ex`: `sound_list` (both layers,
showing which wins), `sound_import`, `sound_trim`, `sound_apply` (write into the
library and route a key to it), `sound_delete`. Read verbs `:safe`; anything
writing the library `:restricted`, because a sound effect is a file the app will
later play unattended. `Sound.route_keys/0` is the validation source, so a
typo'd key is refused at the verb.

*Acceptance, from the archived roadmap:* a voicemail becomes a routed sound
effect end to end, from the CLI alone, with no UI involved.

**Why deferred.** The GUI got built first and covers the operator's own use, so
nothing stopped. Fully specified — no design needed, just the writing.

**What makes it expensive later.** It doesn't get expensive; it stays *absent*,
which is the actual cost. Every other authoring surface in this product is
reachable by the agent, and this one is a room the agent cannot enter — so
"turn that voicemail into my notification chime" is a thing the app can do and
the assistant cannot.

---

### The chime designer — the third half that never shipped

**What.** Inherited 08-02 when `SOUND_STUDIO_ROADMAP` was archived (its Phase 4,
never built). `SoundGen`'s tone-spec language as an editor: frequency, onset,
duration, amplitude, octave partial — the five fields `tone/5` already takes.
Live render on change, preview, save to `<workspace>/sounds/` plus the spec
JSON, with the shipped 16 loading as starting points so *tuning* is the common
path rather than starting from a blank canvas.

**Preview must go through WebAudio, not a `blob:` URL** — CSP declares no
`media-src`, so media falls back to `default-src 'self'`, which excludes
`blob:`. A blob preview works in dev and fails only in the packaged app.
`dtmf.js` is the precedent.

**Why deferred.** The 07-30 scoping locked three halves — editor, surface,
designer — and the first two consumed the four days. This is the third.

**What makes it expensive later.** Nothing structural: `SoundGen` already speaks
the spec language and the surface it would live in is built. But this is the
largest unbuilt thing in this file, and per the rules above it should be
**promoted back to its own roadmap** if it is genuinely wanted rather than
picked up as a leftover.

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

### Two Trading browser tests the LiveView suite cannot stand in for

**What.** Inherited 08-03 from `TRADING_TAB_CRITICAL_REVIEW_ROADMAP` (archived);
its Stage 6 closed every other test but these. In a real browser: (1) changing
account and range **redraws the actual SVG path**, and (2) the tooltip,
accessibility label, headline figure and plotted line **all agree**.

**Why deferred.** The LiveView tests around them are strong — in-flight account
and symbol switches, fail-closed last-four collisions, unconfirmed orders never
reaching a write tool, confirmed payloads that cannot be replayed. What none of
them can see is the rendered DOM, because `render_hook` never touches JS.

**What makes it expensive later.** These two guard the exact defect the review
opened on: a chart that keeps displaying the previous account's data. That class
of bug is invisible to every test currently in the suite, and it is a *financial*
display error — the one kind this codebase has consistently refused to ship.
Pair with the Chart Build walk below; both need a browser and nothing else.

---

### Decompose TradingLive — it grew back

**What.** The `TRADING_TAB_CRITICAL_REVIEW` flagged a **1,728-line** LiveView.
`CODE_QUALITY_REFACTOR` Phase 3A then cut it **3,503 → 1,900 (−46%)** across two
passes. It is **2,174 lines today** — Chart Build and the rest of this week
landed on top of it.

**Why deferred.** Nothing is broken, and the technique is proven twice here: map
lines-per-responsibility, extract, then `import` the extracted module so the
template call sites stay byte-identical. It needs no design, only an afternoon.

**What makes it expensive later.** It is the file every Trading change touches,
so it accretes by default. The important part is what the two data points show
together: **the extraction held and the file still regrew**, so this is a rate
rather than a one-time job. Either it gets re-cut periodically, or something has
to make growth visible — the same lesson as the cycle count, which drifted back
to 3 on 08-03 because nothing asserted it.

---




## Rules of engagement

- An item leaves this file by being **done** or by being **promoted** to a real
  roadmap because it turned out to need a design. It does not leave by rotting.
- If an item has sat here through two dev summaries without moving, that is a
  signal it is either not actually worth doing (delete it, and say so) or it is
  more important than "leftover" implies (promote it).
