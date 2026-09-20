# 09-19-26 — The engine that had already left

The operator asked one question — *wait, the cut-up engine is still in the
repo?* — and it was. `STUDIO_ROADMAP` was deleted on 09-02 with the sentence
"the cut-up engine is its own project now." The roadmap went. The code stayed,
for seventeen days, under a size gate that was protecting about fifteen
thousand lines whose fate was already decided.

Today it went, and a week-old red gate went green beside it.

---

## What landed on main

| | |
|---|---|
| (this commit) | The cut-up engine deleted whole: 16 modules, 18 commands (214 → 196), the Studio's Voice Library tab, and the `sound-cutup` skill seed. Map: `roadmaps/surfaces/CUTUP_DELETION_ROADMAP.md` |
| (next commit) | `Orchestration.Shift` gains the `@type t` that `Duty.go_on_duty/2`'s spec had named since 09-13. Dialyzer: exit 2 → exit 0 |

75 files, **+752 / −20,710** with the maps and this summary. `lib/` 102,534 → 91,030 lines. `mix precommit`
green at 3,486 tests and 362 JS tests.

## What had to be true first

"The voice feature" and "the voice library" shared a directory, a recorder and a
word, and were otherwise unrelated. Before anything was cut it was established
that **`BusterClaw.Voice.*` references no `Cutup` module** — Vox2B's only ties
to the Studio's audio code are `SoundStudio.read/write`, `Capture.Take.decode/2`
and the `VoiceRecorder` JS hook, and all three sit *below* the engine. One file,
`capture/take.ex`, was both halves at once; it was trimmed 379 → 167 rather than
deleted.

## The part worth carrying forward

**Deleting a seed from the repo deletes it from nowhere else.** A workspace
seeded last month would have gone on teaching an agent 24 verbs that answer
`unknown_command` — the 08-18 BusterPhone defect, arriving through the skills
door instead of the jobs one. `BusterClaw.Seed.retire/2` is the existing rule
pointed the other way: a file whose bytes still match a version we shipped is
ours to remove; an edited one is the operator's and stays. The guard was broken
on purpose and seen to fail.

## Two costs, stated

- **Four Mix tests left with a tab that was not Mix's.** They proved the
  selection, trim, clipboard and undo stacks survive leaving Mix, by switching
  to the Voice Library. With one tab there is nowhere to leave to. The design
  stays; the tests are owed back the day a second sub-tab exists (`98cbad8`).
- **`commands/sound.ex`'s owed split was retired by deletion** — 2,464 → 1,122.
  The Corpus third both reviews wanted extracted no longer exists to extract.

## What the map did not know

Checked against git, the config and CI rather than read off `SUPERMAP`:

- **A pre-release has existed since 08-23** (`r1-0.1.0`, Intel). Two maps still
  said no release had been published.
- **The release path has had no commits since 08-23**, across 69 others.
- **CI has been red on every run since 09-03.** Dialyzer since 09-13 on one
  missing type (fixed today); `Build & verify` on macOS-only tests running on
  Ubuntu, which is accepted; the Browser engine job for a reason not yet read.

## Unwalked

Vox2B's recorder, in the real app, after the cut. The server path is untouched
code under green tests. Ninety seconds in Chrome or a packaged build closes it —
not the dev shell.

## Next

Cut `r1-0.1.1` from this `main` so the fresh-machine walk tests the app that
ships today rather than one 69 commits old. Then `G-46`.
