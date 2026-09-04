# 09-03-26 — The operator at the keyboard, relaying what he sees

Yesterday built the Voice map with the operator away. Today he opened the app and
worked from the screen: *this shouldn't be here, this needs a UI, this doesn't
work.* Seven commits — and the day ended with the model saying "What is my name?"
in his own voice.

---

## What landed on main

| | |
|---|---|
| `95c5500` | The dock tab is **Sketch**, not Studio |
| `a0ceef2` | Engine settings — reference clip, device, steps, guidance, path |
| `c4e95a8` | **Record your voice once**, then type anything and hear it |
| `a70aa7d` | **Spoken messages** — notes to yourself, fired as notifications; four verbs |
| `a1034ff` | Three weeks of uncommitted docs, and the 08-22 review that was never filed |
| `0e01bcd` | **The size gate had been red since 09-02**, and two smoke checks were vacuous |
| `2edfaf0` | The record button looked enabled and did nothing |

**Gate at close:** 4342 Elixir tests / 0 failures, bun 352 / 0, 2 accepted cycles.
219 commands. The file-size gate is red on `place_panel.ex` — an unrelated
moon-dial clock change sitting uncommitted in the shared tree, not ours.

---

## The morning: three surfaces the operator pointed at

**The Studio tab** became the Sketch Pad's. Removing it would have deleted the
only door to a finished surface, so the tab moved to a new `/sketch` route —
thirty lines, because `SketchComponent` needs nothing from a parent. The
`/studio` *route* stays: deleting it broke ~30 tests, twice, and **a route
deleted out from under its own suite is an afternoon of guessing which failures
were meant.**

> `status_live_test` asserted `href="/studio"` and claimed it proved the tutorial
> deep-links to its surface. It never did — the href it matched came from the
> **dock nav bar**. Removing the dock tab turned it red, which is the only reason
> anyone learned it had been reading the wrong element. Removed, not repaired.

**Record your voice** reuses the Studio's `VoiceRecorder` hook rather than
copying its AudioWorklet and Float32 encoder. There is no training step: VoxCPM
clones zero-shot, so "have the model learn my voice" is a file the app **saves**.

**Spoken messages** in Settings → Notify: *a spoken message is a notification
whose sound is a rendered line.* One clause in `Sound.for_notification/1` honours
`metadata["sound"]` ahead of the routing walk, and the modal, snooze and audit
feed come free. Nothing waits on the render. Four verbs, 215 → **219**.

**One request declined:** VoxCPM reading the chat live. Measured RTF makes that
impossible; `say(1)` already does it. *"Ah!! Ok we don't want that then."*

---

## The evening: three things that were broken and one that was never true

### "My edits aren't in the app" — two stale layers, not one

The operator's checkout was **19 commits behind** (`lib/buster_claw/voice/` did
not exist in it), *and* a `mix phx.server` from 07:09 still held :4000.
`tauri.conf.json` has **no `beforeDevCommand`** — only `devUrl` — so
`cargo tauri dev` never starts Phoenix. It points a window at whatever already
serves that port. Rebuilding the app changes neither layer.

### "The homepage is blinking and tabs are missing"

Not CSS, not a crash. The page was doing a **full load every 3–9 seconds**, so
the JS-populated `#tab-strip` and the dock's five brand `<img>` tabs never
survived long enough to paint. Proof, in the order it was obtained:

1. A value set on `window` vanished and `performance.timeOrigin` jumped — a new
   page, not a re-render.
2. A `beforeunload` listener logging a stack into `sessionStorage` named it:
   **`onJoinError → onRedirect → LiveSocket.redirect → navigate`**. A LiveView
   was failing to *join*, and LiveView's recovery for that is a full-page
   redirect — which re-joins, fails, and loops.
3. A second server on `PORT=4001` against the same tree mounted cleanly and held
   33 seconds. **Clean there means the running process is at fault, not the code.**

The 13-hour-old server had hot-reloaded across 19 commits into a state where
`StatusLive` could not join — it never appeared in its logs at all. Restarting
fixed it completely. **Three theories died first** (stale `cache_manifest.json`,
`phx-track-static` mismatch, a stuck `TerminalWorkspace` request); each was
cheap to kill and each would have been a confident wrong answer.

### The size gate had been red for four commits

`dbbc54d` grew `skills.ex` 356 → 426 past its 379 cap without raising it. Four
commits were pushed over it and reported green, because **`test` is step 5 of 9
in the precommit alias** — `check_cycles`, `check_file_sizes` and `check_rust`
all run after the ExUnit summary, and a `| tail` long enough to show "4342 tests,
1 failure" scrolls the actual failure past. **"Green" means `EXIT: 0`, not "the
test line looked fine."**

Raised to 469 with the reason recorded: most of that growth is a **ledger** — a
digest list per seed that grows by one line every time a default is corrected and
may never be pruned. A zero-headroom cap would fail on the next correction and
teach everyone to bump it unread.

Two smoke checks in the same sweep were worse than stale — they were **vacuous**.
`smoke_command_surface.sh` asserted three commands that no longer exist and
probed `POST /mcp`, deleted in the pull-queue cut. A smoke test naming a deleted
surface does not fail loudly; it stops meaning anything.

### The record button

Two checks in one hook decided "armed?" separately, with opposite conventions:

    paint()   dataset.armed !== "false"    // absent -> ARMED, enabled button
    start()   dataset.armed !== "true"     // absent -> DISARMED, returns

They agree whenever the attribute is present and disagree **exactly when it is
absent**. The Studio always sets it, so the Studio never saw the gap. The new
Settings → Voice recorder leaves it off — the case `paint()`'s own comment
documents as supported — so the button rendered enabled and did nothing. No
error, no console message, nothing to find it by. Now one exported `isArmed()`
both call sites share, pinned by a test that was checked by reintroducing the
defect and watching two of four go red.

---

## The voice, measured — and it sounds like him

**The first real end-to-end render happened today.** `voxcpm design` produced a
valid 1.92 s WAV. It took **440 s of wall clock**, and the split is what matters:

* **Model load ≈ 162 s, paid once per CLI invocation.**
* Generation ≈ 223 s → RTF ≈ **116** generation-only, ≈ **229** all-in.

So the "RTF ≈ 97" carried in the roadmap was optimistic. **The consequence is that
batching is not an optimization, it is the design:** sixteen chimes rendered one
at a time pay that 162 s load sixteen times — 45 minutes of pure loading before
any audio. `Chimes.render_set/1` already does the right thing.

Then the operator recorded a reference clip — 13.28 s, 44.1 kHz, **zero clipped
samples** — and asked the model "What is my name?" Six minutes forty later:

> *"It is very quiet though but it remarkably sounds like me."*

**The clone works.** The level does not. Measured against the 16 design-mode
renders already in the cache:

| | duration | peak | rms |
|---|---|---|---|
| 16 design renders | 0.64–1.92 s | −1.0 to −10.4 dBFS | −16.8 to −29.6 |
| the clone | 0.64 s | **−36.2 dBFS** | **−50.1** |

26 dB below the quietest of the others. The cause is upstream: the reference
peaked at **−20.2 dBFS** against the app's own target band of **−12 to −6**, so
the model had a quiet example and reproduced it. A +35.2 dB peak-normalize to
−1 dBFS proved in one second what a re-render would have cost seven minutes.

**`--normalize` is not the fix.** The CLI source says `help="Enable text
normalization"` — it expands numbers and abbreviations. Wiring it would have
invalidated all 17 cached renders and changed nothing audible. Checked before
recommending, which is the only reason that isn't in this file as a mistake.

> **A correction worth keeping.** This summary said earlier that the pipeline had
> never produced audio. Wrong: 16 renders from 09-02 were sitting in the cache.
> The workspace is `~/Desktop/BusterClaw-DataZone`, not `tmp/dev-workspace` —
> the dev default was never the one in use. **Reading an empty directory is not
> evidence until you have confirmed it is the directory being written to.** The
> mistake was lucky: those 16 renders became the baseline that made the clone's
> level anomaly obvious rather than arguable.

---

## Still open

- **Re-record hotter**, aiming inside the −12 to −6 band. The root fix: it raises
  the voice relative to room noise, which amplification afterwards cannot.
- **A normalize stage on renders.** Even the 16 design renders span 9 dB. But
  `SoundStudio.normalize/2` lives in the module the Studio takes with it when it
  spins off — so extract the peak-normalize into the voice stack rather than
  reaching into the Studio for it. **A structural call, not a small one.**
- **The chime set**, in one batch. Most of an hour, unattended.
- **`supabase functions deploy voice`**, then phone +1 844 484-8755.
- **`place_panel.ex`** is over its cap in the working tree — the moon-dial
  clock's author owes the gate a reason in the same commit as the growth.
