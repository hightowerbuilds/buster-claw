# 09-13-26 — The robot is briefed, the human is not

One document today, no code. A user-experience review of the whole app, written
from the user's chair rather than the compiler's: design, flow, where things
are, whether it makes sense, and how creatively the AI is actually used. It is
at `daily-growth/roadmaps/UX_REVIEW_09-13-26.md`, beside the two code reviews.

The day's one finding worth carrying forward is small enough to fit in a line
and large enough to explain most of the rest.

---

## What landed on main

| | |
|---|---|
| (this commit) | `UX_REVIEW_09-13-26.md` — the review, scored across six dimensions, with a ten-item fix list by leverage and a section of claims re-verified against source |

---

## The scorecard

| Dimension | Score |
|---|---|
| Visual design | 8/10 |
| Flow, first run to first value | 3/10 |
| Where things are | 4/10 |
| Does it make sense | 5/10 |
| AI creativity | 9/10 |
| AI utilization | 3/10 |

The gap between the last two rows is the review.

## The finding

The home chat's system-prompt addendum is the SVG drawing guide plus the
voice-clip guide. Nothing else. The agent in the front door has never been told
what Buster Claw is, that a CLI exists, or that Gmail, Notes, Calendar, the
queue, skills, or memory are reachable. A 660-line introduction written for the
model is regenerated on every launch, and the only thing that references it is
one terminal cheat-sheet prompt. No `CLAUDE.md` or `AGENTS.md` is seeded into the
workspace, so the harness's own auto-context never picks it up either.

The unattended Dispatcher gets the opposite: a precise, threat-aware brief. The
app knows exactly how to brief an agent and briefs only the robot on a shift.
Nearly every "the AI should obviously do X here" gap in the review — Notes,
Calendar, the Library, Activity narration, settings by voice, "put that on the
queue" — is already built as a command and unreachable for that one reason.

## The rest, in a line each

- **On-duty has no button.** Nothing in the web layer calls `start_shift`; the
  wizard promises a Stand down button in a bar where none exists.
- **The browser has no "ask about this page."** The co-presence machinery is
  excellent and its only door is on a different top-level tab.
- **The dock's Settings button opens Appearance.** Which agent CLI to run is
  three clicks deep behind two synonyms.
- **Calendar under Workspace, Activity under Home, the Library with no viewer,
  the Manual with no link.** Music is a dock transport nothing can drive;
  Studio is linked from one tutorial tile and nowhere else.
- **Four help systems disagree** on step counts, the install command, and where
  the wizard ends.
- **The genuinely awesome list is long:** the SVG channel, voice-clone chimes,
  the payment handoff that records who confirmed, email as command, the
  intake-only phone, the weather shader, steer-vs-queue honesty, and the best
  empty states in any indie Mac app.

## Method, and what it cannot claim

Four parallel read-throughs of every user-facing surface, then the sharpest
claims re-checked by grep because the 09-05 review was wrong six times from
reading alone. Thirteen behavioural claims are listed as verified in the
review's last section. Headless Chrome would not screenshot the running dev
server, so the review says nothing about rendered pixels; where it speaks about
feel, it says it is inferring from markup.

## Later the same day: the three doors, built

The operator read the review and said build the first three. Roadmap first
(`THREE_DOORS_ROADMAP.md`, `1b8b35b`), then the three phases, one session, no
subagent fan-out — a standing preference recorded that afternoon.

| | |
|---|---|
| `f666f06` | **Brief the assistant.** `CLAUDE.md` + `AGENTS.md` seeded at the workspace root through `BusterClaw.Seed`; a 60-word pointer rides the chat addendum. The full introduction stays on disk: 17k tokens re-sent every turn was the obvious fix and the wrong one |
| `dfbb55f` | **Go on duty from the dock.** `BusterClaw.Mailman` is the Gmail poll loop inside the BEAM (it only ever lived in the escript); `BusterClaw.Duty` owns readiness incl. the trusted-sender check nothing on that path made before; `DutyDockLive` takes the music player's slot; `/duty` renders idle |
| (Phase 3) | **Ask about this page.** A chrome toolbar button hands the active tab to Home by URL over the existing `browser_app_navigate`; the home page stages a sentence and sends nothing. Zero Rust |

**Gate at close:** `mix precommit` exit 0 — 4,106 tests, 0 failures, bun 346/0,
2 accepted cycles, size inventory holds (four caps raised with reasons, one of
them FROZEN), Rust green.

**What the build corrected in the map** — the roadmap's Part IX has the list.
The sharpest: the first brief named four commands that did not exist, in a
document whose own decision said never to list commands; and Phase 3's
`handle_params` was illegal because Home is also a child pane in Split view,
which two existing tests knew and the map did not.

**Three gates still need the running app or a person:** the real-CLI chat
smoke, the Tauri walk of the Ask button, and the on-duty email round trip.

## Later still: the dev launcher stops leaving servers behind

Opening the app to walk those gates found why launches kept failing.
`scripts/dev.sh` ended in `exec cargo tauri dev`, and `exec` discards the EXIT
trap, so every launch that started Phoenix left it running when the window
closed. One had been up since 09-06, pulling phone events into the dev database
all week, and this morning's `config/config.exs` change made it answer every
request with a 500. The fresh launch then died on `:eaddrinuse`, because a
terminal inside Tractor Beam exports `PORT=4400`, its own server's port.

| | |
|---|---|
| (this commit) | `dev.sh` runs cargo as a child so the trap fires; a watchdog stops Phoenix if the script is SIGKILLed; `PORT` is pinned to 4000; a leftover, unhealthy or `.env`-stale Phoenix from this repo on :4000 is replaced, and any other process there is named and never stopped. The old stale-server path ran `pkill -f phx.server`, which would have killed Tractor Beam's server too |

**Verified, with the guard broken first.** `scripts/smoke_dev_launcher.sh` runs
the launcher against fake `mix`, `cargo` and Phoenix in temp folders: 9
scenarios, 23 checks, all pass. Against the pre-fix script it fails 12 —
closing the window, Ctrl-C, closing the terminal and SIGKILL each leave Phoenix
running, and it reuses orphaned and foreign servers.

The smoke's own first two drafts were wrong, and both would have shipped a
false green: a launcher held its output pipe open so three scenarios "passed"
without running, and the Ctrl-C and hangup scenarios signalled before the window
existed, so the pre-fix script passed them too.

## And the Vox tab stopped crashing the app

With the app finally open, the operator found one fault: every click on Home →
Vox2B crashed the whole desktop app. macOS left three crash reports, each a
SIGABRT from TCC — *"must contain an NSMicrophoneUsageDescription key"*. The
recorder opened the microphone in `mounted()` so the level meter would already
be moving, and on 09-05 the reference recorder had moved onto the Vox tab's
default page. Rendering the recorder was a microphone request, and the unbundled
`cargo tauri dev` binary carries no usage description, so macOS killed it. The
repo's `Info.plist` has the key; only a packaged `.app` carries it.

| | |
|---|---|
| (this commit) | The microphone opens on a click — Turn on microphone, then Record, then Stop — so the meter still runs before you commit to a take. In the desktop window talking to a dev server, the hook refuses and says where recording does work (a browser at 127.0.0.1:4000, or the packaged app) without touching the microphone API. The Vox and Studio recorders share the hook, so both changed |

**Guards broken first:** putting `open()` back in `mounted()` fails two of the
new JS tests; skipping the dev-window refusal fails one. `mix precommit` exit 0
— 4,109 tests, 0 failures, bun 351/0.

**Still owed:** recording has never been exercised in a packaged build (V.4a).
The dev window now refuses rather than crashing, so the first real desktop
recording will be that walk.
