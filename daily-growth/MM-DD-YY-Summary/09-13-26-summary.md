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

## Next

The review's top three fixes are small and unlock most of the rest: brief the
chat agent at `status/chat.ex:147`, give on-duty a button where the music
player sits, and put an agent button in the browser toolbar. None of them is
started.
