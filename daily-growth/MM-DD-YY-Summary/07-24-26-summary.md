# 07-24-26 — The Notes tab becomes the minutes of the day

The operator's call: the homepage Notes tab should show "our daily
journal/summary" — the minutes of the day — as one rolling document per day,
appended chronologically by both the agent and the operator, with the
operator's (rarer) items marked so they stand out. Days Buster Claw isn't
used get no document. The freeform Obsidian-style notes surface is gone;
this shipped in its place, plus a layout fix so the app window itself never
scrolls again.

## 1. `BusterClaw.Journal` — one dated document per day

New workspace surface at `<workspace>/journal/YYYY-MM-DD.md`. `append/3`
(`:agent` | `:operator`) creates the day's file on first entry (title line
`# Minutes — YYYY-MM-DD`), stamps each entry under a `###### HH:MM` heading —
operator entries suffixed ` — OPERATOR` — and broadcasts
`{:journal_appended, date}` over PubSub. Safety posture is *stronger* than
the old notes surface: filenames derive exclusively from `Date` values
(`get/1` parses ISO 8601 before touching the filesystem), so no
caller-controlled string ever becomes a path segment. 7 unit tests.

## 2. Command surface — `journal_append` / `journal_read`

The agent writes minutes through the audited surface, not by hand-editing
files: `journal_append` (mutate/restricted) and `journal_read` (read/safe;
defaults to today, reads empty on a fresh day so the first look isn't an
error). The catalog-invariants safe-tier snapshot guard caught the promotion
exactly as designed; `journal_read` was reviewed (local workspace markdown
only, same posture as `document_read`) and added to the snapshot. Catalog
entries live in `Catalog.Library`; impl in `Commands.Journal`; facade
delegates keep the single policy choke point.

## 3. UI — `JournalComponent` replaces `NotesComponent`

Same "Notes" sub-tab, new surface: day rail (newest first, "today" tag),
rendered markdown reading pane, and a composer that always appends to
*today* as an OPERATOR entry — the journal is chronological, so there is no
retro-editing surface. `StatusLive` subscribes to Journal PubSub and
`send_update`s the component, so an open tab live-updates the moment the
agent appends (covered by a real-broadcast LiveView test). The composer
textarea sits in a `phx-update="ignore"` wrapper keyed by a rev counter:
agent appends re-render the reading view without clobbering a half-typed
draft. `Notes` module + component + tests deleted — nothing else referenced
them; existing `notes/*.md` files remain on disk, just no longer surfaced.

## 4. History import — 50 days back to 2026-04-18

Two one-time merges into the operator's workspace journal
(`~/Desktop/BusterClaw-DataZone/journal/`): the 41 repo dev summaries
(`daily-growth/MM-DD-YY-Summary/`) and the 32 runtime "Daily Minutes" the
on-duty agent was already writing to the workspace's `mm-dd-yy-summary/`
folder — overlapping days merged with a `---` separator, originals left in
place. Because a day's document is only *created* by its first append,
imported days keep accepting appends seamlessly.

## 5. Instruction repoint — agents now use the journal

`Introduction` (generates the workspace `INTRODUCTION.md`) and the seeded
job descriptions told agents to hand-write `mm-dd-yy-summary/` files; both
now instruct `journal_append`/`journal_read`. The workspace `INTRODUCTION.md`
was regenerated in place (`mix run --no-start`) and the seeded-only-if-missing
`mail-triage.md` patched by hand, so the convention flips without waiting for
a relaunch. The standing wrap-up cycle now mirrors each dated dev summary
into the journal so the Notes tab stays the one place the whole history reads.

## 6. `fit_viewport` — the app window stops scrolling

Root cause found while eyeballing the new tab: the homepage used the
layout's default `min-h-screen` shell, so every `min-h-0 flex-1` /
`overflow-y-auto` chain in the tab panes was inert — the page just grew.
`full_bleed` clamps height but also strips the centered max-width/padding,
so `Layouts.app` gained a third mode, `fit_viewport`: `h-screen
overflow-hidden` *with* the centered `max-w-7xl` + padding kept. Home uses
it, the home `<section>` completes the `min-h-0` chain, and every tab pane
now scrolls itself — journal reading pane and day rail, chat transcript,
calendar, trading.

Suite state at close: 1314 Elixir tests green (plus Rust gates), formatter
clean, `--warnings-as-errors` clean. In-flight commerce Phase 5 work
(`BrowserControl.Commerce` + friends) deliberately left uncommitted —
separate arc, separate commit.

---

# Second arc — Phase 5 lands: commerce, cart in, human pays

Back to the browser engine. The in-flight Phase 5 work (handoff on
`payment_stop`, `awaiting_human → done`, `browser_agent` ledger source,
`Cart`, `Commerce.confirm_purchase`) was reviewed against the roadmap spec
and finished: two spec bullets were unbuilt, plus one real integrity gap.

## 7. The cart lives on the run — the ledger can't disagree with the human

The spec's handoff shows "the total and full cart," but the run didn't know
the cart — and `confirm_purchase` billed whatever cart the *caller* passed,
which nothing tied to what the human saw. Now: `AgentMode.put_cart/2`
attaches the cart while shopping (recorded as a watchable `:cart` trajectory
step), the payment handoff **freezes** it (`put_cart` refuses in
`awaiting_human`) and carries the summary in the handoff step + reply meta,
and `confirm_purchase` lost its cart argument entirely — it bills the run's
frozen cart, so ledger-equals-shown holds by construction, not by test.

## 8. The confirmation page is captured — best-effort, never entry-losing

`AgentMode.capture_confirmation/1`, allowed only in `awaiting_human` (it
receipts the human's own checkout; it deliberately can't give a working
agent eyes): CDP `Page.captureScreenshot` → PNG at
`<workspace>/browser-control/captures/<run_id>-confirmation.png` (run id
sanitized to one path component), recorded as a `:capture` step.
`confirm_purchase` wires the path into tx metadata; a dead engine or a
capture-less stub degrades to a receipt-less ledger entry, never a lost one
— non-raising end to end, exit-trapped at the Commerce boundary.

## 9. One found bug + coverage

`fsm_reply` broadcast `{:mode, %{from, to}}` after updating state, so `from`
always equaled `to` — now reports the real pre-transition mode. Commerce
tests 6 → 10: handoff-shows-cart, cart-step, cart-frozen, capture-receipted,
capture-degrades, no-cart refusal, billed-equals-shown (asserted against the
handoff meta, not a caller-side cart). Suite at close: 1317 green + Rust
gates. Deferred, matching the arc's phasing: the LiveView/Tauri handoff-card
rail (the roadmap's deferred UI slice) and the live Stripe-style checkout
walk (acceptance criterion 2, needs the packaged app).
