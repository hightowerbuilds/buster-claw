# Modularization — a feature-by-feature decomposition

**Scoped 08-08-26 · Status: SCOPED, not started.**

A read-through of all 304 modules and 68,536 lines under `lib/`, feature by
feature, asking one question of each: *is this file big because the feature is
big, or because the file is doing several jobs?* Those are different problems and
this roadmap refuses to treat them the same way.

**Why now.** The last two decomposition efforts each closed successfully and each
was followed by regrowth. `CODE_QUALITY_REFACTOR_ROADMAP` took `mix xref` cycles
from 6 → 2 and a third appeared within a day, unnoticed, because nothing asserted
the result — that is exactly why `scripts/check_cycles.sh` now names its two
accepted cycles rather than counting them. TradingLive was cut 3,503 → 1,900
(−46%) and had grown back to 2,174 by the time the file was deleted. And
`LEFTOVERS.md` recorded `status_live.ex` at **1,460** lines on 08-08; it measured
**1,526** when this roadmap was written, the same week.

So the load-bearing conclusion, inherited and now measured a third time: **this is
a rate, not a job.** Any phase here that lands without something holding it will
be undone. That is why Phase 0 is the gate and not the reward.

---

## The method (proven twice here — do not invent a third)

From `feedback: Split LiveViews by purity, not feature`:

1. **Map lines-per-responsibility first.** Not lines-per-function. The output is a
   number per concern, and if the numbers don't add up to the file you have not
   understood it yet.
2. **Extract to a module, then `import` it** at the call site so template call
   sites stay **byte-identical**. A diff where the template changed is a diff
   where you cannot tell a refactor from a regression.
3. **Do not rename across the boundary.** A regex rename over `.ex` files silently
   severs hook↔markup contracts and the suite stays green, because `render_hook`
   never touches JS. If a phase below needs a rename, it sweeps `assets/js` in the
   same commit and adds a lockstep test.
4. **One phase, one commit, suite green, straight to main.**

---

## The measurement (08-08-26)

| Layer | Files | Lines |
|---|---:|---:|
| `lib/buster_claw/` (core) | 237 | 47,399 |
| — of which root-level, no subdirectory | 67 | 17,859 |
| `lib/buster_claw_web/` | 67 | 21,007 |
| `test/` | 227 | 40,763 |
| `assets/js/` | — | 9,098 |
| `desktop/tauri/src/` (excl. build artifacts) | — | ~3,500 |

### The web layer, with its markup share separated out

Markup share is the whole diagnosis. A file that is 82% `~H` is *long*; a file
that is 11% `~H` is *overloaded*. They need opposite treatments.

| File | Lines | `~H` | Verdict |
|---|---:|---:|---|
| `components/explore_panel.ex` | 1,577 | **82%** | long — split by panel |
| `live/status_live.ex` | 1,526 | **11%** | overloaded — 1,356 lines of logic |
| `live/sound_studio_component.ex` | 1,235 | **20%** | overloaded — 987 lines of logic |
| `components/phone_panels.ex` | 952 | 80% | long |
| `live/settings_live.ex` | 928 | 43% | mixed — four features + a 406-line render |
| `live/calendar_component.ex` | 866 | 42% | mixed |
| `components/home_widget.ex` | 688 | 81% | long, but already well-factored inside |
| `live/setup_live.ex` | 648 | 46% | mixed |
| `live/appearance_live.ex` | 633 | 59% | long |
| `components/chat_panel.ex` | 618 | — | **already good** — 14 small components |
| `components/gws_panels.ex` | 513 | 80% | long — one 300-line function |

### The longest single functions in the repo

| Lines | Where |
|---:|---|
| 657 | `introduction.ex:72` `markdown/0` — a prose heredoc |
| 406 | `live/settings_live.ex:327` `render/1` |
| 342 | `components/explore_panel.ex:901` `cmd_panel/1` |
| 314 | `commands/catalog/orchestration.ex:8` `entries/0` |
| 311 | `components/sound_studio/arranger.ex:54` `arranger/1` |
| 300 | `components/gws_panels.ex:149` `workspace_console/1` |
| 276 | `components/phone_panels.ex:534` `contacts/1` |
| 264 | `controllers/browser_chrome_controller.ex:44` `page/2` — an HTML string |

---

## Read this before proposing work: what is already modular

Four clusters were read and found **correct as they stand**. Touching them is
churn, and this section exists so a future pass does not rediscover them as
"large directories."

- **`commands/` (5,481 lines, 34 files)** — a facade (`Commands`) delegating to
  per-domain modules, with the catalog split the same way under
  `commands/catalog/`. `catalog/orchestration.ex`'s 314-line `entries/0` is a
  *data literal*, and it belongs in code: compile-time validation of the command
  surface is worth more than the line count costs. Leave it.
- **`browser_control/` (3,179 lines, 17 files)** — the largest file is 613 lines
  and every module has one job (`Cdp`, `Page`, `Pool`, `Session`, `Scope`,
  `Egress`, `Screencast`, `Commerce`, `Secrets`). This is what the rest of the
  codebase should look like. It got here through `BROWSER_SHELL_REBUILD_ROADMAP`,
  which is the precedent worth citing.
- **`scene3d/` (2,456 lines, 5 files)** — already a pipeline with one stage per
  module: `Geometry` → `Project` → `Labels` → `Svg`, `Types` holding the contract.
  Shipped 08-08 and archived clean.
- **`components/chat_panel.ex`** — 618 lines across **14** function components,
  none over 90 lines, with `chat_bubble/1` dispatching on role by pattern match.
  It is the house's best-factored web file and is the model for Phase 1.

---

## Phase 0 — Make regrowth visible **(do this first; everything else depends on it)**

*Inherited from `LEFTOVERS.md` → "Decompose the surviving hotspots", where it is
named as the only part of that item that stops the next 2,000-line LiveView from
arriving unnoticed.*

**What.** `scripts/check_file_sizes.sh`, added to the `precommit` alias next to
`check_cycles.sh`, holding a table of `path → max lines` for every file this
roadmap touches. Modelled deliberately on `check_cycles.sh`: it asserts a **named
inventory with reasons**, not a total, and it fails in **both** directions —
a file that grows past its cap fails, and a file that drops well under its cap
fails too, so the number gets ratcheted in the same commit that earns it.

**Seeded at today's measurements, not at aspirations.** The gate's first job is
to stop the bleeding; each phase below then lowers its own line as it lands.

**Why it goes first.** Every later phase is a one-afternoon extraction whose value
decays without this. Phase 0 is cheap, it is the only phase that cannot be undone
by the next feature, and shipping it first means Phases 1–8 each get to *lower a
number in a file*, which is a far better completion signal than a line count
someone re-measures by hand a week later.

**Acceptance.** Add a line to a capped file; `mix precommit` fails naming the file
and the cap. Delete 200 lines from a capped file; it fails asking for the ratchet.

---

## Phase 1 — The markup-heavy panels: long, not overloaded

**Files.** `explore_panel.ex` (1,577 / 82%), `phone_panels.ex` (952 / 80%),
`gws_panels.ex` (513 / 80%), `home_widget.ex` (688 / 81%).

**What.** These are not doing several jobs; they are one job written at length.
Each becomes a directory of siblings under `components/<feature>/`, one module per
panel, with the parent keeping only the tab registry and the dispatch:

- `explore_panel.ex` → `components/explore/{intro,site,ntf,stub,models,gws,cmd,browser}.ex`
  plus `explore/shared.ex` for the four leaf components it already has
  (`example/1`, `prompt/1`, `copy_command/1`, `external_link/1`). Its
  `@tabs` registry and `tab_keys/0` stay put — `EXPLORE_TAB_ROADMAP` decision 4
  makes that the single source of truth the parent guard reads, and moving it
  would recreate the exact two-list bug that shipped Phone as a button the server
  refused.
- `phone_panels.ex` → `components/phone/{event_log,playback,contacts}.ex`. Its
  three biggest functions are 276 / 263 / 210 lines and correspond one-to-one.
- `gws_panels.ex` → `components/gws/{accounts,workspace_console}.ex`. The
  300-line `workspace_console/1` is the whole reason this file is on the list.
- `home_widget.ex` → `components/home/{comms,notify,place}.ex`. **Lowest value
  in the phase** — it is already 15 small functions and reads fine; it earns its
  split only for the cap in Phase 0, so do it last or skip it and cap it as-is.

**Risk: low, and it should be kept low deliberately.** Function components with
no state and no events of their own. `import` the new modules into the parent so
every call site stays byte-identical — no `<ExplorePanel.cmd_panel …>` becoming
`<Explore.Cmd.panel …>`, because that is a rename across a boundary and rule 3
applies.

**Acceptance.** `git diff` shows zero changes inside any `~H` block. Existing
LiveView tests pass untouched.

---

## Phase 2 — `StatusLive` becomes a page coordinator

**The file.** 1,526 lines, **11% markup** — so ~1,356 lines of logic in a module
whose job is "the homepage." It currently owns chat, contacts, telephony,
notifications, weather/sky, music, studio, notes, calendar, shaders and Explore.
Its `render/1` is 173 lines; the other 1,183 are the problem.

**Lines per responsibility** (the map rule 1 demands, done):

| Concern | Approx. lines | Where |
|---|---:|---|
| Chat — dispatch, delivery, projection, transcript, SVG/scene banks | **~500** | `137–161`, `528–752`, `957–1077`, `1167–1350` |
| Studio — selection, clipboard, undo/redo, trim, history | ~250 | `335–435`, `824–848`, `1089–1164` |
| Contacts / comms / telephony relay | ~180 | `171–256`, `272–312`, `454–468`, `793–815` |
| Weather + sky shader refresh | ~130 | `513–527`, `774–780`, `861–956` |
| Notifications | ~90 | `257–269`, `469–512`, `781–792` |
| Tabs, mount, render, music relay | remainder | — |

**What.** Extract in that order — chat first, because it is a third of the file
and the only one with real internal structure:

- `live/status/chat.ex` — `dispatch_chat/3`, `do_send/4`, `announce_delivery/3`,
  `apply_chat/3`, `push_msg/6`, `collect_svgs/2`, `extract_scenes/1`,
  `scenes_for/2`, `load_chat_history/2`, `maybe_autotitle/3`, the zoom handlers,
  and the `@max_chat_messages` / `@max_chat_svgs` caps that belong with them.
- `live/status/studio.ex` — the `studio_*` and `trim_*` handlers, `open_mix/1`,
  `mutate_open_mix/2`, `step_history/3`, `push_studio_history/2`.
- `live/status/comms.ex` — contacts, trust, the activity-row formatting
  (`activity_row/2`, `kind_label/1`, `activity_snippet/1`, `snip/1`,
  `relative_time/1`), and the telephony relays.
- `live/status/weather.ex` — `load_weather/1`, `mount_weather/1`,
  `maybe_fetch_sky/1`, `push_sky/1`, the `handle_async(:weather, …)` bodies.

**The one hard constraint, and it is a real one.** `EXPLORE_TAB_ROADMAP` records
the house convention that home panels render behind `:if`, which **discards
component state on every tab switch** — which is precisely why sub-tab selection
and studio state live in `StatusLive` rather than in the components. So these
extractions are **plain modules taking and returning `socket`**, not
`live_component`s. Converting any of them to a LiveComponent would silently
change state lifetime on tab switch, and no test in the suite would see it.

**`handle_event` stays in `StatusLive`.** Phoenix routes events to the LiveView;
the clause bodies delegate one line deep into the extracted module. Moving the
clauses themselves needs macro plumbing that costs more than it buys.

**Acceptance.** `status_live.ex` under 600 lines. `status_live_test.exs` passes
with **no edits** — including the home sub-tab tests, whose own comment notes the
guard is a whitelist "not a formality."

---

## Phase 3 — `SoundStudioComponent`: catalog out, editor stays

**The file.** 1,235 lines, 20% markup → ~987 lines of logic in a
`live_component`. There is already a `components/sound_studio/` directory
(`arranger` 377, `overlays` 230, `sidebar` 202, `format` 50, `catalog` 46) — so
the **markup** was split and the **logic** was not. That is the whole finding.

**What.** The source catalog is pure and comes out first: `groups/0`,
`group_keys/0`, `mix_items/0`, `import_items/0`, `sound_items/0`,
`recording_items/0`, `music_items/0`, `resolve_source/1`, `find_source/2`,
`occurred/1` — roughly 180 lines that read five libraries and return a list, with
no socket in sight. It becomes `BusterClaw.Notifications.StudioCatalog` in
**core, not web**, because nothing about it is a rendering concern and the CLI
surface the Sound Studio still lacks (`LEFTOVERS`: "the Studio has no CLI") will
need exactly this module the day it gets written.

Then the upload/import pipeline (`handle_import_progress/3`, `validate_import`,
`cancel_import`, `install_bundled`, `max_import_entries`) → `sound_studio/import.ex`.

What remains — clip and track editing, render, trim, assign — is the component's
actual job and stays.

**Bonus, nearly free.** `notifications/sound_gen.ex:179` and
`notifications/sound_studio.ex:720` both define `ms_to_samples`, with different
arities and the same intent. One of them is wrong the day the sample rate stops
being a constant. Collapse to one.

**Acceptance.** `StudioCatalog` has its own unit test with no LiveView in it —
which is currently impossible and is the point.

---

## Phase 4 — `SettingsLive`: four features sharing a `render/1`

**The file.** 928 lines, of which `render/1` is **406**. It holds Google
Workspace (accounts, Gmail labels, Gmail search, Gmail sync, Calendar sync),
model policy, the profile form, and recovery — four unrelated features whose only
relationship is a tab strip.

**What.** Split by feature into `live/settings/{gws,models,profile}.ex`, each
owning its own assigns, handlers and section markup. `gws` is the big one: 8 of
the 23 `handle_event` clauses and all of `assign_gmail_forms/2`,
`assign_calendar_form/2`, `account_from_params/1`, `gws_tab/1`. `models` is a
clean unit already — `assign_model_policy/1`, `put_model/3`, `model_note/3`,
`model_error/1`, `model_display/1`, `source_note/1`, `surface_label/1`,
`model_target/1` — and it maps exactly onto `BusterClaw.ModelPolicy`.

**These may be real `live_component`s**, unlike Phase 2 — Settings is a route,
not an `:if`-gated home panel, so the state-lifetime constraint does not apply.
Confirm that against `settings_tabs.ex` before committing to it.

**Note while in here.** `defp button_outline` at `settings_live.ex:925` is a
class string in a function — the seed of Phase 8.

---

## Phase 5 — `Agent.Chat` **(needs a design first; do not start it as an extraction)**

**The file.** 1,376 lines, a GenServer per conversation, and the honest reading is
that **it is not obviously wrong.** Its moduledoc states its boundary precisely
("owns ordering, persistence, the transcript, audit, delivery modes, and the
queue; does not know how any harness works"), the transport abstraction is real
(`ChatTransport`, with `OpenCodeServer` and `CodexAppServer` behind it), and the
one-shot-vs-persistent lifecycle table in that moduledoc is the kind of thing that
exists because getting it wrong hangs a conversation.

**So the finding is narrower than "split it".** `LEFTOVERS` already says this half
needs a design because *its state transitions aren't written down anywhere*, and
reading the file confirms that: `status` moves between `:idle` and `:running`
across `handle_call({:submit, …})` ×3, `handle_info({port, {:exit_status, …}})`
×3, `handle_info({:chat_event, …})`, `handle_info({:run_timeout, …})` ×2,
`interrupt_running/1`, `dispatch_next/1` and `finish_run/1` — eleven-plus sites,
no diagram, and the correctness argument lives in prose.

**Therefore Phase 5 is two steps and the first one is not code:**

1. **Write the state machine down** — states, events, transitions, and which
   transitions are legal under each transport lifecycle. As a `@moduledoc`
   table or a doc under `docs/`. This is worth doing *even if the split never
   happens*, and it is the cheapest defect-finder in this roadmap: the four
   defects that only the real-CLI smokes caught (`CHAT_STEERING_ROADMAP`) were
   all transition bugs.
2. **Then, and only then**, split along the lines the moduledoc already draws —
   most plausibly delivery/queue (`enqueue`, `steer_or_queue`, `dispatch_next`,
   `barge`, `reorder`) and event projection (`project_event`, `apply_line`,
   `capture_session`, `charge_turn`, `stash_result`) as pure modules over the
   state struct, leaving the GenServer as transitions and I/O.

**Do not reorder this phase ahead of 1–4.** It is the only one that can break a
shipping surface.

---

## Phase 6 — The browser's hand-built HTML **(and the CSP hole underneath it)**

*Inherited from `LEFTOVERS.md` → the code-quality roadmap's tail. Re-measured and
confirmed here.*

**What.** Five controllers assemble standalone HTML documents as heredoc strings —
`browser_home` (329), `browser_chrome` (311), `browser_history_page` (181),
`browser_workspace` (141), `browser_pages` (123) — **1,085 lines**, each carrying
its own copy of the same `#121212` / `#f4f1ea` / `#ff4d1c` CSS block. The single
largest is a 264-line `page/2`. Move to HEEx function components over one shared
browser-surface layout, with the industrial palette defined once.

**The part that is not cosmetic.** That scope in `router.ex:102` has **no
`pipe_through`**, so those responses receive no `put_secure_browser_headers` and
**no CSP header at all** — the one part of the app the 08-03 `script-src 'self'`
tightening does not reach. The pages escape every interpolation through
`html_escape/1`, so this is defence-in-depth rather than a live hole, but it is
1,085 lines of string-built markup sitting outside the policy, and it grows every
time the in-app browser gains a page.

**Do the header in this phase, not a later one.** It is the reason this phase
outranks its line count.

---

## Phase 7 — Content out of code

Three files are large because they contain **prose**, not logic.

- **`introduction.ex`** — a **657-line** markdown heredoc inside `markdown/0`,
  regenerated into the workspace on launch. It is a document. The pattern to copy
  already exists and is named in `EXPLORE_TAB_ROADMAP`: `BusterClaw.UserGuide`
  keeps markdown in files with `@external_resource` + compile-time embed, so it
  ships in releases *and* hot-reloads in dev. Split into `priv/introduction/*.md`
  sections composed at read time. **`command_surface_markdown/0` (line 731) stays
  in code** — it is generated from the live catalog, which is the one part that
  must not drift.
- **`skills.ex`** — `default_shader_designer` is a 111-line markdown literal, and
  it is not alone. Same treatment. This also unblocks a `LEFTOVERS` item that is
  currently blocked on nothing else: moving `Scene3d.guide/0` out of the homepage
  system prompt and into a `handler_kind: reference` skill, which today costs a
  recompile to reword and is paid for on **every turn**.
- **`finance/sources.ex`** (550) — a 16-source registry. **Leave it in code.**
  Same reasoning as `catalog/orchestration.ex`: compile-time validation of a
  registry whose whole design assumes free tiers and endpoints will move is worth
  more than the lines. Listed here only so it stops being re-proposed.

---

## Phase 8 — The missing design primitives

`CoreComponents` has **six** components (`flash`, `input`, `header`,
`page_wordmark`, `table`, `list`) — essentially the Phoenix generator's defaults
plus a wordmark. Meanwhile the same long Tailwind class strings are copy-pasted
across the web layer: one button style appears **6** times verbatim, a link style
**9**, a display heading **8**, a section heading **6**, a chip **4**.

**What.** Promote the repeated strings to named components in an `ic_*` module
(the `ic-` utility convention already exists — 175 uses across the web layer):
`ic_button` (primary / ghost / outline), `ic_panel`, `ic_eyebrow`,
`ic_display_heading`, `ic_section_heading`, `ic_chip`, `ic_empty_state`.

**Sequencing matters.** Do this **after** Phases 1–4, not before. Extracting a
component from four call sites is cheap; extracting it from four call sites that
are simultaneously moving between files is how a refactor eats a weekend. It also
inherits the palette work from Phase 6 — the browser pages define the same three
hex values by hand and should end up drinking from the same source.

**One constraint from the deleted Scene3D roadmap:** the **validated 5-slot
palette** is sole-sourced in `Scene3d` and is to be *promoted*, never copied. If
Phase 8 needs those colours, it takes a dependency on them.

---

## Phase 9 — The tail

Cheap, mechanical, and individually not worth a phase.

- **Nested modules in production** (`LEFTOVERS`, re-measured — still exactly 4):
  `search.ex`, `browser_control/egress.ex`, `browser_control/pool.ex`,
  `browser_control/agent_mode/trajectory.ex`. Against the repo rule; extract.
- **The Dialyzer baseline** — `.dialyzer_ignore.exs` is 179 lines. Burn it down in
  the risk order `LEFTOVERS` already sets: audit/policy → dispatch →
  orchestration → browser → filesystem → UI.
- **Ignored returns in durability and security paths** — replace with explicit
  handling. Same source.
- **Shared formatting helpers.** `format_duration` lives in `phone_panels.ex:915`,
  `format_time` in `calendar_component.ex:775`, `relative_time` + `snip` in
  `status_live.ex:234`. Three files, three private copies of "make a time
  human." One `BusterClawWeb.Format`. Do it during Phase 2, which touches two of
  the three anyway.

---

## Sequencing, and what each phase costs

| Phase | Scope | Risk | Order rationale |
|---|---|---|---|
| **0** Size gate | 1 script + alias | none | Holds every phase after it. Nothing lands before this. |
| **1** Markup panels | 4 files → ~12 | low | Proves the technique on files with no state. Momentum. |
| **2** `StatusLive` | 1,526 → <600 | medium | Biggest single win. State-lifetime constraint is the trap. |
| **3** Sound Studio | catalog → core | low | Unblocks the missing `sound_*` CLI surface. |
| **4** `SettingsLive` | 4 features | low | Mechanical once 2 is done. |
| **6** Browser HTML | 1,085 lines | low | Carries a real CSP fix — may jump the queue for that alone. |
| **7** Content out | 2 files | low | Unblocks the Scene3D guide relocation. |
| **8** Design primitives | web-wide | low | **Must** follow 1–4. |
| **9** Tail | scattered | low | Fold into whichever phase is already in the file. |
| **5** `Agent.Chat` | design, then split | **high** | Last. Step 1 (write the state machine down) has value even if step 2 never happens. |

---

## Rules of engagement

- **A phase is not done when the code moves. It is done when Phase 0's cap for
  that file is lowered in the same commit.** Otherwise this document joins the
  two roadmaps whose results were undone by not being asserted.
- **Zero behaviour change.** If a phase wants a behaviour change, that is a
  separate commit with its own test, before or after — never inside the move.
- **Templates stay byte-identical.** A refactor diff that touches `~H` content is
  a refactor diff you cannot review.
- **Sweep `assets/js` in the same commit as any rename.** The Elixir suite cannot
  see JS and will stay green through a severed hook contract.
- **Do not touch** `commands/`, `browser_control/`, `scene3d/`, or
  `chat_panel.ex`. They were read; they are right. That finding is part of the
  deliverable.
