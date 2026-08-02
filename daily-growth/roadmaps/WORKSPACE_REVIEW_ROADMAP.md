# The workspace — critical review + rebuild roadmap

**Scoped 08-01-26.** The workspace is the product's one durable promise: *"everything
is markdown on your disk. No lock-in; `grep` works."* It is also the first thing a
new user sees after setup, and right now what they see is a filing cabinet of
empty labelled drawers.

This document is in two parts. **Part I** is the review — what is actually wrong,
with evidence from the code and from a real workspace on disk. **Part II** is the
roadmap to fix it.

---

# Part I — Review

## The evidence

Ground truth, the dev workspace on this machine (`~/Developer`, resolved from
`config/config.exs`):

| Entry | Files | What's actually in it |
|---|---|---|
| `INTRODUCTION.md` | — | 861 lines, 57 KB, regenerated every launch |
| `cmd-list/` | 2 | README + catalog.json |
| `job-descriptions/` | 4 | 3 job files + README |
| `journal/` | **0** | *empty* |
| `mcp/` | 1 | robinhood.json |
| `memory/` | 3 | policy + trusted senders/numbers |
| `music/` | 1 | **README only** |
| `notes/` | **0** | *empty* |
| `pages/` | 1 | MANUAL.html |
| `shaders/` | 1 | **README only** |
| `skills/` | 3 | 2 skills + README |
| `sounds/` | 1 | **README only** |
| `studio/` | 1 | **README only** |

Thirteen top-level entries. **Seven carry no user content** — four are a README
and nothing else, two are entirely empty. And this is a *used* workspace; a fresh
install is worse, because the dirs that do have content here (`mcp/`, `memory/`,
`job-descriptions/`, `skills/`, `pages/`) got it from months of use.

And thirteen is the *observed* count, not the real one. Tracing every
`Artifact.workspace_path/1` call in `lib/` turns up **twenty** top-level entries
the code can create:

> **dirs** `library/` `sources/` `analysis/` `memory/` `shift/`
> `job-descriptions/` `skills/` `cmd-list/` `shaders/` `sounds/` `music/`
> `studio/` `journal/` `pages/` `appearance/` `checks/` `mcp/`
> `browser-control/` `.claude/`
> **files** `INTRODUCTION.md` `buster-claw` `.browser-bookmarks.json` `STOP`

Seven of those never appeared in the folder above because nothing had triggered
them yet. **That is itself the finding:** no two installs have the same layout,
and which one you get depends on which features you happened to use.

### Measured: what a brand-new user gets

Scaffolding a workspace into an empty temp dir (08-01, after Phase 0's
consolidation, before any cleanup) produces **16 top-level entries**:

```
.claude            core         1 file      library            core       2 dirs
INTRODUCTION.md    core         file        memory             core       3 files
buster-claw        core         file        music              on_demand  README only
cmd-list           on_demand    2 files     pages              on_demand  1 file
job-descriptions   core         4 files     shaders            on_demand  README only
skills             core         3 files     sounds             on_demand  README only
analysis           deprecated   EMPTY       studio             on_demand  README only
sources            deprecated   EMPTY       journal            on_demand  EMPTY
```

**Seven of sixteen hold nothing a user made** — three empty directories and four
that contain only a README explaining what could go in them. This is the number
the roadmap is judged against.

## 1. Nothing declares the layout

There is no module, no list, no test that answers *"what should this folder
contain?"* The layout is an emergent property of scattered `ensure/0` calls:

- **`application.ex`** — 9 calls at boot (Introduction, Pages, WorkspaceCLI, Jobs,
  Sound, Music, SoundStudio, Journal, Appearance).
- **`jobs.ex:61-63`** — `Jobs.ensure/0` *also* calls `Skills.ensure()`,
  `Shaders.ensure()` and `TerminalCommands.ensure()`. Three directory creators
  hidden inside a fourth's implementation, invisible from the boot list.
- **`workspace_live.ex:409`** — `set_workspace_root/1` runs a **different, smaller**
  set (`ensure_workspace_dirs`, Introduction, Pages, WorkspaceCLI).
- **Lazily, on first use** — `dispatch_projector.ex` (`shift/`), `trading.ex`
  (`mcp/`), `browser/checks.ex` (`checks/`), `appearance.ex` (`appearance/`).

Every other finding below is downstream of this one. You cannot declutter a space
that nothing describes.

## 2. Changing your workspace folder gives you a broken one

Direct consequence of §1, and a real bug. `set_workspace_root/1` creates four
things. It does **not** call Jobs, Sound, Music, SoundStudio, Journal, Appearance,
Skills, Shaders or TerminalCommands.

Move your workspace in-app and `job-descriptions/`, `skills/`, `sounds/`,
`music/`, `studio/`, `journal/`, `shaders/` and `cmd-list/` simply do not exist
until the next app restart — including the seeded job descriptions and the
trusted-sender policy template the unattended shift reads. Nobody noticed because
the boot path papers over it on the next launch.

## 3. Most of a fresh workspace is scaffolding for things the user hasn't done

Four directories exist solely to hold a README explaining what *could* go in them:
`music/`, `shaders/`, `sounds/`, `studio/`. `journal/` is created empty.

The intent was discoverability — "drop a `.wgsl` here". But the app already tells
you this at the point of use (Settings → Appearance says exactly that), and an
empty directory is a poor teacher: it looks like something is missing rather than
something is available. The cost is paid by every user on every open of the
folder; the benefit accrues to the few who go looking.

## 4. Scaffolding the code itself admits is dead

`Library.Artifact`, on `sources/` and `analysis/`:

> The latter three are organizational scaffolding today (those domains are
> DB-backed) and are **reserved for file exports**.

Reserved since the Phoenix rewrite. Still empty. `memory/` — the third of that
trio — is genuinely used, which is why the comment reads as reasonable and the
two dead directories have survived.

## 5. An orphan nothing creates and nothing removes

`notes/` is in the workspace. **No code in `lib/` creates it.** It predates
`journal/`, which replaced it. Nothing swept it up, because no process has ever
been responsible for removing a workspace directory.

The workspace only ever accumulates. That is the disposition that produced this
review.

## 6. The biggest, loudest file is not for the user

`INTRODUCTION.md` — 861 lines, 57 KB — sits at the top of the folder, is
regenerated on every launch, and its own first line says *"treat this as
read-only reference."* It is a prompt for the model, formatted as the most
prominent document in the user's personal folder.

## 7. Two naming registers, jumbled together

Some directories are named for **what they hold**: `music/`, `sounds/`, `pages/`,
`journal/`, `skills/`. Others are named for **the feature that created them**:
`appearance/` (background images), `cmd-list/` (one catalog.json), `shift/` (one
file, `Dispatch.md`), `mcp/` (one config), `job-descriptions/`.

A user reading the folder cannot tell which are theirs to edit, which are the
app's bookkeeping, and which are inert.

## 8. Dev runs against a layout we would never ship

`config/config.exs` sets `workspace_root: Path.expand("../..", __DIR__)` — the
**parent of the repo**. In dev the assistant's workspace is `~/Developer`, the
same folder holding your source checkouts. That is why `journal/` and `notes/`
sit next to `buster-claw/` up there.

Not a distributed-build defect, but it means the cluttered-first-open experience
is invisible to us during development. We have never looked at what we ship.

---

# Part II — Roadmap

**Goal.** A new user opens their workspace folder and sees a handful of entries,
every one of which either has their content in it or is obviously theirs to fill.
No empty drawers, no bookkeeping, no 57 KB machine file.

**Non-goal.** This is not an app rewrite. The workspace layout, its creation, and
its ownership are the subject; features stay where they are.

**Constraint that shapes everything.** Existing installs have real files in these
directories. Every phase that moves or removes anything ships with a migration
that is *idempotent and never destroys user content* — the same posture as the
Appearance image-pool migration (rewrite pointers, leave bytes alone).

---

## Phase 0 — One module owns the layout — **SHIPPED 08-01** (`16c8213`)

**What.** A `BusterClaw.Workspace` module that *declares* every top-level entry:
name, owning module, tier, purpose, and whether it is seeded. Every existing
`ensure/0` moves behind it; `application.ex` calls `Workspace.ensure/0` once
instead of nine times; `Jobs.ensure/0` stops secretly creating three unrelated
directories.

**Why first.** Findings 1–7 are all downstream. Until one place describes the
layout, "declutter" has no definition and no test can defend it.

**Lockstep guard.** A test asserting that no module calls
`Artifact.workspace_path/1` with a top-level segment the registry doesn't
declare — the same idiom as `SettingsTabsTest` and the Rust `acl_lockstep` suite.
This is what stops the next feature from quietly adding a fourteenth directory.

**Free fix.** §2 disappears: `set_workspace_root/1` calls the same
`Workspace.ensure/0` as boot, so moving your workspace produces a complete one.

**Ships when.** The registry exists, all creators route through it, the guard
passes, and moving the workspace root produces a layout identical to a fresh boot.

---

## Phase 1 — Delete what is dead — **SHIPPED 08-01** (`16c8213`)

**What.** Remove `sources/` and `analysis/` (§4) and `notes/` (§5) from the code,
plus a one-time sweep that deletes each **only if empty**. A non-empty one is left
alone and logged — a user may have put something there, and we do not get to
decide that was a mistake.

**Why.** Cheapest real win. Three entries gone from every install, no design
required.

---

## Phase 2 — Stop materializing empty directories — **SHIPPED 08-01** (`16c8213`)

> **The drop-zone question resolved as (a)**: the owning surfaces call
> `Workspace.ensure_entry/1` at the point of use (Settings → Appearance for
> `shaders/`, Notify for `sounds/`, the Pages button for `pages/`), so a folder
> appears exactly when the user opens the feature that explains it.

**What.** Tier the registry:

- **core** — created eagerly. The short list: `library/`, `memory/`, `shift/`,
  `skills/`, `job-descriptions/`, and the `buster-claw` launcher.
- **on-demand** — created on first *write*, not at boot: `music/`, `sounds/`,
  `studio/`, `shaders/`, `appearance/`, `journal/`, `checks/`, `pages/`, `mcp/`,
  `cmd-list/`.

The four README-only stubs (§3) stop being created. Their guidance consolidates
into one workspace `README.md` that lists the optional folders and what each is
for — one file the user can actually read, instead of four they have to go find.

**Open question for the on-demand tier.** Some of these are *drop zones* — the
user is meant to put a file in before the app ever writes one (`music/`,
`shaders/`, `sounds/`). On-demand creation makes them appear only after the app
writes, which for a drop zone may be never. Two candidate answers: (a) the
relevant UI gets a "create this folder" affordance at the point of use, or (b)
drop zones stay core. **Recommend (a)** — it puts the folder in front of the user
at the moment they want it, which is the discoverability §3 was reaching for.

**Expected result.** Fresh install: `README.md`, `buster-claw`, `library/`,
`memory/`, `shift/`, `skills/`, `job-descriptions/`. **Seven entries, all with
content**, down from thirteen-plus.

---

## Phase 3 — Naming and grouping — **DECIDED A (operator, 08-01) + SHIPPED 08-01**

> Shipped as: `job-descriptions/` → `jobs/`, `appearance/` → `backgrounds/`,
> `shift/Dispatch.md` → top-level `Dispatch.md`. The dated dispatch diary
> (`shift/<date>/`) is machine bookkeeping, so it moved to
> `.buster-claw/dispatch/<date>/` — Phase 4's register, same commit. Existing
> installs relocate via the same merge-don't-clobber migration as the audio
> consolidation; Appearance's workspace-relative Settings pointers are rewritten
> **before** its pool migration reads them (order matters — a stale prefix made
> `next_empty_slot` misread filled slots).

**What.** Fix §7. Two candidate shapes:

- **A — flat, renamed.** Keep one level; rename the feature-named entries to
  content names (`appearance/` → `backgrounds/`, `job-descriptions/` → `jobs/`,
  `shift/Dispatch.md` → a top-level `Dispatch.md`). Cheap, low-risk, and after
  Phases 1–2 the flat list is short enough to read.
- **B — grouped.** Nest the asset dirs under one parent (`media/` holding music,
  sounds, studio, shaders, backgrounds). Fewer top-level entries; costs a real
  migration, breaks every stored path, and requires rewriting the agent guide and
  any skill that names a path.

**Recommend A.** Phases 1–2 already cut the top-level count by more than half, and
B's nesting buys tidiness at the price of the one property that makes this folder
valuable — that a human or a `grep` can find things without learning a hierarchy.
B is only worth it if the flat list is still too long after Phase 2, which we will
be able to *see* rather than guess.

**Decide after Phase 2, with the real list in front of us.**

---

## Phase 4 — The machine file stops being the loudest thing in the room — **SHIPPED 08-01**

> `INTRODUCTION.md` now installs at `.buster-claw/INTRODUCTION.md`; the stale
> root copy is deleted by the layout migration (machine-generated, regenerated
> at the new home every boot). The onboarding prompts (Get Started quick-chat,
> the terminal welcome) state the new path, and the workspace `README.md` holds
> the top slot.

**What.** `INTRODUCTION.md` (§6) moves out of the user's eyeline — a dotfile
(`.buster-claw/INTRODUCTION.md`) or a clearly-marked subdirectory — and the
workspace `README.md` from Phase 2 takes the top slot as the one file addressed
to the human.

**Care required.** The agent is told where this file is, in the guide and in
skills; the path is part of how models orient. Moving it means updating the guide,
the skills that reference it, and any job description that points at it — and the
`Introduction.ensure/0` install path. Cheap to do, easy to do incompletely.

---

## Phase 5 — Look at what we ship — **HALF SHIPPED 08-01; packaged walk OPEN**

> Dev's `workspace_root` now points at `tmp/dev-workspace` (repo-local,
> gitignored, deletable) instead of `~/Developer` — delete it any time to watch
> a fresh scaffold. **Still open:** the packaged-install walk (fresh folder →
> setup wizard → open in Finder → count). Pair it with the R1 QA pass, alongside
> LEFTOVERS' byte-range walk and `SOUND_STUDIO_ROADMAP` Phase 5 — one build,
> four answers.

**What.** Point dev's `workspace_root` somewhere that is not the repo's parent
(§8), and walk a **packaged** install end to end: fresh folder → setup wizard →
open the folder in Finder → count what's there.

**Why last, and why non-optional.** Every phase above is judged by exactly one
thing: what a new user sees on first open. We have never once looked at that. The
Appearance work this same day shipped without a visual pass and that is recorded
as its open item — this roadmap should not repeat it.

---

## Order and rationale

0 → 1 → 2 are strictly sequential: the registry defines the thing, deletion
shrinks it, tiering stops it regrowing. 3 waits for real data from 2. 4 is
independent and can slot anywhere after 0. 5 is the acceptance test for all of it.
