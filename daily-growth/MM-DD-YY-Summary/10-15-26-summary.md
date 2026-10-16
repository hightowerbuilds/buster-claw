# 10-15-26 — Four terminals, three chords, and panels you can pick up

The day opened on the attachment path from yesterday and closed on the work
area. The live walk went first: a real iPhone receipt photo mailed from the
trusted address through `gmail_send`, pulled by `gmail_sync` byte-identical
into `attachments/gmail/<id>/`, named on the Library doc and on `Dispatch.md`,
read by the agent (ampm, Oak Harbor, $40.00 of unleaded), and sent back
in-thread by `dispatch_reply --attachments`. Zero errors. One papercut: the
CLI's 5 s default receive timeout fails the *client* on a multi-MB send while
the server goes on and sends it — Sentinel logs `gmail_send (ok)` either way.
Not fixed; pass `--timeout`.

Then the terminal. The ask was four things in one breath — multiple
terminals, no "+" and no copy-key button, the sidebar button and ⌘T create,
a limit of four — and the map was written first, as the operator prefers.
The code told it what shape to take: the Terminal the sidebar opens is a
work-area *panel* with one fixed slot, so a second terminal is a new kind of
key, not a second `live_render`; a hidden panel keeps its PTY by design, which
is right for every panel except one counted against a limit; and two files in
the path are FROZEN with one line of headroom between them.

Three asks followed while reading, each a decision in the map:

- **⌘1 ⌘2 ⌘3 are Work Area, Settings and Browser — the only three.** In the
  DOM strip, the native Tabs menu (renamed; ⌘4–9 gone) and the Browser chrome.
- **Four panels are two columns of two, five are three columns with two
  stacked.** A fourth preset, *Paired columns*; Side by side and Stacked hold
  up to three and hand over on their own at four.
- **Pick a panel up by its header and drop it on another's spot;** the rest
  slide over. The arrangement's shape depends only on count and preset, so the
  drag is a local relabelling of the tree and only the drop talks to Phoenix.

---

## What landed on main

| | |
|---|---|
| (this commit) | `TERMINAL_PANELS_ROADMAP` and its build, D1–D9: four terminal slots in `WorkbenchState` (the first keeps `workbench` so a running shell survives), sidebar and ⌘T create via one `requestNewTerminal` with a 300 ms guard against the native accelerator, × on a terminal pane ends the PTY through the hook's `closeSession()`, split and copy-key deleted, ⌘1/2/3, the Paired columns preset, and drag-to-reorder. |

21 files. `mix precommit` green at 3,425 tests; both new guards were broken on
purpose and seen to fail; `tab_strip.js` went 535 → 511 against a frozen cap
of 536, `chrome.js` 856 → 854 against 859.

## Walked, and not

In Chrome against the dev server (no PTY there): four from the sidebar with
distinct session keys, the `4 / 4` badge and the refusal pulse, × frees the
lowest slot and it is the one reused, ⌘T on the work area and from Settings
(lands with the one-shot flag consumed), ⌘2 and ⌘1, the five-panel paired
layout, and a synthetic drag of Chat from first to last.

**Open — Phase 5 in the desktop app:** the busy prompt on ×, that a closed
slot's shell is really gone, the renamed Tabs menu, the upgrade path for a
shell already running. Also noticed: an embedded terminal sets `page_title`,
so the window reads "Terminal 4 · Buster Claw" once the last slot mounts.

## Two things worth remembering

- A `git checkout -- <file>` to undo a break-the-guard mutation took the
  file's whole uncommitted edit with it. Undo a mutation with the same string
  replacement that made it.
- Side by side was capped at three along with Stacked, on the reading that a
  fourth column is the same complaint turned sideways. One line in
  `available?/2` if four across should stay available.

---

## Later the same evening — four more

| | |
|---|---|
| (second commit) | **Workspace deconstructed:** the page is the Directory alone; Notes and Calendar are work-area panels, one each, listed after Workspace in the sidebar. The note relay moved into `StatusLive`; eighteen tests moved hosts with three substitutions; `/calendar` untouched. **The file-tree rail:** its hover-only row actions reserved a third of the width while invisible — now overlays — and the rail resizes (192–720 px, remembered). **A focus guard** in the terminal hook: xterm no longer grabs the keyboard on attach while the operator is typing elsewhere — a guess at "the terminal pops open over the chat while I type", **not reproduced** in Chrome; awaiting the operator's detail. **`PHONE_REMOVAL_ROADMAP`** scoped (map only, nothing deleted): ~−7,000 lines across six phases; the paid tier stood on this leg, open question. |

`mix precommit` green at 3,424 tests.

---

## Late — the phone comes out

| | |
|---|---|
| (third commit) | **BusterPhone removed whole**, the same night the map was written: `Telephony` and its five modules, `TrustedNumbers`, the ten `phone_*` commands (193 → 183), the Phone page and panel, Explained's phone line and the atlas's phone desk, the recording route, the Supabase relay, the drain, the Twilio and Supabase Clinch keys, Sentinel's PIN fragment, the voicemail and SMS notification routes and chimes, and the two triage briefs — retired by digest through `Seed.retire/2`, so an unedited copy leaves on the next launch and an operator's edit is named and kept. One drop migration for `telephony_events`. One rule added: a saved layout naming the retired `phone` panel loses that pane, not the layout. One thing restored: adding a contact, which the Phone tab had owned since 09-13, is back on the corner widget's Contacts tab, created and trusted in one step. Five seams the map had not listed (the sound probe's `event_id`, the sound board, the Studio's Recordings group, the sound board page, the Explained atlas) were found by the compiler and the tests and taken too. 144 phone tests gone, 11 added. |

`mix precommit` green at 3,280 tests. Still the operator's: release the
toll-free number, delete the Supabase project, rotate the Twilio token, clear
the stored secrets from the Clinch, drop the six `.env` keys — and the question
of what the paid tier is now.
