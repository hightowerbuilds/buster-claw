# Buster Claw code quality review — 2026-09-05

**Status:** Open review. Nothing in it has been acted on; the roadmap at the end
is the proposal.

**Snapshot:** `a9311c0` plus the working tree (four modified generated Tauri
schema files, four untracked generated permission files).

**Scope:** the three questions asked — *is the codebase fully modularized*, and
*where is the dead, orphaned, or suppressed code* — answered from tooling first
and reading second. The 08-22 review covered security and product; this one
does not repeat it, and its six holes stand as written.

**Method.** Every gate the repo owns was run, then five sweeps the repo does not
own: an xref graph analysis for layering and coupling, an AST pass over every
`def` for length and duplicate bodies, a whole-corpus identifier index for
public functions with no caller, a hook↔markup and route↔controller contract
check, and a generated-artifact drift check against git. The full suite, the
Rust suite, and the bun suite were run to completion, not tailed.

---

## Blunt verdict

**The architecture is modular. The files inside it are not all, and the public
surface is about twice as wide as the callers justify.**

The structural numbers are unusually good for a codebase this size: the core
never imports the web layer except at the application root, the web layer never
touches the database, the compile-time dependency cascade is nearly flat, and
the two remaining cycles are named and accepted with reasons. Someone has
worked hard on this and the guards they left behind are holding.

What is not modular is inside the modules. Six files are frozen at a size the
repo itself calls "already too big". Three render functions are longer than
most whole modules. 2,220 functions are public, and 125 of them are called by
nothing outside their own file except a test. And the biggest subsystem on
main, the cut-up engine, has a decided exit and no exit date, which means the
size gate is currently protecting fifteen thousand lines whose fate is to be
deleted.

The dead-code picture is better than it looks from the headline count. Most
candidates are small. Two of them matter: a security module that is tested and
never applied, and a heartbeat column that is declared, migrated, and never
written.

Suppression is nearly absent and every instance found is written down beside
the thing it suppresses. That is the best result in this review.

---

## What the gates prove

| Gate | Result |
|---|---|
| `mix compile --warnings-as-errors` | clean |
| `mix credo --strict` (774 files, 70 checks) | 0 issues |
| `mix test` | 7 doctests, 4,081 tests, 0 failures, 22 excluded |
| `bun test assets/js` | 346 pass, 0 fail |
| `cargo test` (incl. ACL lockstep) | pass |
| `scripts/check_cycles.sh` | 2 accepted cycles, as inventoried |
| `scripts/check_file_sizes.sh` | inventory holds |
| `scripts/check_docs_drift.sh` | OK |
| xref | 457 files, 1,459 runtime edges, 157 compile edges |

The 22 excluded tests are the `:browser_engine` tag, opt-in because they launch
a real Chromium. The 9 CI failures on `ubuntu-latest` are macOS-only tools and
were left by decision on 09-03. Neither is a suppression in disguise.

One thing the green suite hides: a GenServer crash report prints mid-run
(`Last message: :capture_confirmation`). The test passes because the process is
expected to die, but a crash log in a green run trains people to skip crash
logs.

---

## Part I — Is it fully modularized?

### What is right, with the numbers

**Layering.** Exactly two edges go from `lib/buster_claw` to
`lib/buster_claw_web`, both from `application.ex` to the endpoint and telemetry.
That is the one place the rule must be broken. Zero files under the web layer
call `Repo` or import `Ecto.Query`. Every LiveView and controller is routed.
Every `phx-hook` in markup has a hook in `hooks/index.js` and every hook in the
index is used in markup (the 08-13 review found dead Trading hooks; the guard
added then is doing its job).

**Coupling.** The command surface reaches 39 files, the workspace registry 19,
the application root 18. All three are hubs by design. Below them the widest
context reaches 10 files (Google). This is the shape of a system with a single
front door, which is what the README promises.

**Compile-time cascade.** The most-depended-upon core file at compile time has
**2** compile-connected dependents. Editing a context does not recompile the
world. This is rare and worth protecting.

**Cycles.** Two, both accepted, both inventoried by name with reasons in
`check_cycles.sh`. A third appeared once (08-03) and was caught. The guard
asserts the inventory rather than a count, which is the right design.

### Where it is not modular

**1. Six frozen files, two of which broke their freeze.**

`check_file_sizes.sh` marks these FROZEN — "already too big; may shrink, never
grow":

| File | Lines | Shape |
|---|---|---|
| `lib/buster_claw/commands/sound.ex` | 2,464 | 231 clauses, 45 public; 30 `sound_*` verbs |
| `lib/buster_claw/agent/chat.ex` | 1,510 | a GenServer holding queue + run lifecycle + transport routing |
| `lib/buster_claw/commands/web.ex` | 848 | 52 public functions, 101 clauses |
| `assets/js/chrome.js` | 864 | |
| `lib/buster_claw_web/live/vox_component.ex` | 741 | |
| `assets/js/hooks/tab_strip.js` | 664 | |

`chat.ex` had its cap *raised* on 08-08 to absorb attachments; the LEFTOVERS map
files that as a broken promise and says "do not raise this cap again without
extracting first — twice is a pattern." It has not been raised again. It has
also not been cut.

**2. Render functions that are whole pages.**

| Function | Lines |
|---|---|
| `Explained.Phone.phone_panel/1` | 547 |
| `AppearanceLive.render/1` | 465 |
| `Explained.Cmd.cmd_panel/1` | 396 |
| `Explained.Studio.studio_panel/1` | 391 |
| `SoundStudio.Arranger.arranger/1` | 317 |
| `SetupLive.render/1` | 292 |
| `BrowserChromeController.page/3` | 264 |

The Explained tutorials are content files by design, and the 08-08 ruling that
they are capped at "don't grow" is fair. `AppearanceLive.render/1` at 465 lines
is not content; it is a settings page with at least four independent regions
(mode picker, shader catalog, image slots, terminal palette) in one function.
`SetupLive.render/1` is the same shape. Neither is on the size gate's list of
things owed a cut.

**3. The public surface is about twice as wide as its callers.**

Of 2,220 public functions in `lib/`, **125 have no caller outside their own file
except a test.** 92 of those are also used inside their file, which means they
are private helpers declared `def` so a test could reach them. The other 33 are
not used inside their file either (Part II has them).

This matters for modularity because `def` is a promise: anything may call this.
A module with 52 public functions (`commands/web.ex`) or 45 (`commands/sound.ex`)
has no visible interface; the reader cannot tell the four verbs the catalog
dispatches from the forty helpers. Files where the pattern is densest:

| File | Public helpers whose only outside caller is a test |
|---|---|
| `lib/buster_claw/cli.ex` | 10 (`format_*`, `connection_message`, `request_timeout_ms`) |
| `lib/buster_claw/notifications/cutup/mfcc.ex` | 7 |
| `lib/buster_claw/notifications/capture.ex` | 5 |
| `lib/buster_claw/terminal_theme.ex` | 5 |
| `lib/buster_claw/setup.ex` | 4 (`*_complete?`) |
| `lib/buster_claw/agent_backend.ex` | 4 |

There is also a second-order cost. `--warnings-as-errors` flags an unused
`defp` and says nothing about an unused `def`. Every helper made public to be
tested is a helper the compiler can no longer report as dead.

**4. The cut-up engine: a decided exit with no date.**

On 09-02 the operator decided the cut-up engine spins off into its own project;
`STUDIO_ROADMAP.md` was deleted the same day. On main today:

| Where | Lines |
|---|---|
| `lib/buster_claw/notifications/cutup/` | 7,947 |
| Studio surfaces (`studio*.ex`, `sound_studio*.ex`, `components/studio/`, `live/studio/`) | ~7,157 |
| `sound_*` verbs in the catalog that are cut-up rather than library | 26 of 30 |

That is roughly 15,000 lines, 26 commands, 32 entries in the size gate, and the
whole reason `commands/sound.ex` is 2,464 lines. Every modularity decision
downstream of it — whether to split `sound.ex`, whether the `Notifications`
namespace should hold a DSP library — is moot if the engine leaves, and
expensive if it stays. **The sharpest single modularity move available is not a
split. It is partitioning `sound.ex` so that the four library verbs
(`sound_list`, `sound_routes`, `sound_sources`, `sound_probe`) live in one
module and the 26 cut-up verbs in another, so the exit is a file delete.**

**5. Namespace honesty.** `BusterClaw.Notifications` holds timers and chimes,
and also `Cutup` (an MFCC/DTW signal-processing library), `Capture`, `Studio`,
`StudioMix`, `SoundStudio` and `SoundGen`. The module docs are honest about what
each one is; the namespace is not. Related: `BusterClaw.Pocket` and
`BusterClaw.Pockets` are separate modules, and `lib/buster_claw.ex` is the
Phoenix generator's empty placeholder with the stock moduledoc.

**6. Web layer doing OS and file work directly.** Six files under
`lib/buster_claw_web` call `File.*` or `System.cmd` themselves rather than
through a context:

- `lib/buster_claw_web/studio/preview.ex`
- `lib/buster_claw_web/live/notify_settings_live.ex`
- `lib/buster_claw_web/live/status/chat_attachments.ex`
- `lib/buster_claw_web/live/workspace_live.ex`
- `lib/buster_claw_web/controllers/voice_audio_controller.ex`
- `lib/buster_claw_web/controllers/browser_screenshot_controller.ex`

Nine call sites in total. Not many, but each is a path the Sentinel layer and
the workspace registry cannot see.

**7. Duplicate bodies.** Six pairs of functions with structurally identical
bodies after normalising variable names:

| Size | A | B |
|---|---|---|
| 315 | `music.ex:184 rename` | `notifications/sound_studio.ex:634 rename` |
| 299 | `integrations/github.ex:321 pull_request_row` | `integrations/github.ex:325 issue_row` |
| 238 | `browser_history.ex:181 build_match` | `memory.ex:69 build_match` |
| 196 | `ingest/content.ex:134 html_entities` | `search.ex:177 html_entities` |
| 190 | `telephony/pins.ex:158 request` | `telephony/relay.ex:188 request` |
| 181 | `agent/stream_event.ex:172 normalize_codex` | `stream_event.ex:232 normalize_codex_app_server` |

Credo's `DuplicatedCode` check is commented out in `.credo.exs:65`. Six pairs is
a small number, and two of them (`build_match`, `html_entities`) are the kind
that drift apart silently.

---

## Part II — Dead, orphaned, suppressed

> **Every inventory below is a lower bound.** The 08-09 dead-code pass recorded
> why: a `{__MODULE__, :fun}` seed registry is invisible to grep and to
> `--warnings-as-errors`, and a `defp` conversion passed 3,569 tests and would
> have broken seeding at boot. `workspace.ex` and `voice/renderer.ex` both
> carry that pattern today. Nothing here should be deleted on this list's
> authority alone; each item gets the three questions (who calls it, who
> *could* call it by string, what breaks at boot) before it goes.

### Dead modules — 2

**`BusterClaw.AgentToolPolicy`** (`lib/buster_claw/agent_tool_policy.ex`, 82
lines). Its moduledoc calls it "the one place a confined surface gets its denial
list", and it carries the measured finding that the CLI's `WebFetch` is a live
SSRF path into the command API. It is referenced by exactly one file: its own
test. Nothing in `dispatcher.ex`, `agent_runner.ex` or `agent_backend.ex`
consumes `denied_builtins/0`. **This is the 08-22 review's Critical #1 in
miniature: the denial list exists, is correct, is tested, and is applied to no
run.** The fix is wire, not delete.

**`BusterClaw.DataState`** (`lib/buster_claw/data_state.ex`, 49 lines). "Financial
UI must distinguish a fresh value, an old value…" The financial UI was deleted
on 08-08. Referenced only by its own test.

### Public functions with no caller anywhere — 5 that matter

After removing framework callbacks and false positives from HEEx templates:

| Function | What it is |
|---|---|
| `Voice.Chimes.render_all/1` (`chimes.ex:140`) | documented "render every chime, broadcast as each lands"; no surface calls it |
| `Voice.Greeting.rendered_path/0` | the greeting's file path; no reader |
| `TerminalCommands.reset_catalog/0`, `reset_role/1` (`:255`, `:342`) | "restore the shipped defaults"; no button, no verb |
| `StudioMix.clear_effects/2` (`studio_mix.ex:327`) | "the way back to the raw source"; no menu item |

### Public functions whose only caller is a test and which their own file does not use — 30

These are tested behaviours with no production path. Grouped by what they say
about the product:

**Spines with no surface.** Each of these is a feature that has a model and a
test and no UI or verb reaching it:

- `Dispatch.heartbeat/1` (`dispatch.ex:258`) — writes `heartbeat_at`. The column
  is declared in `dispatch/item.ex` and in `shift_assignment.ex`, migrated, and
  **never written by anything but this function, which nothing calls.** Any
  staleness or liveness reasoning on that column is reasoning about `nil`.
- `Telephony.unheard_count/0` (`telephony.ex:234`) — "the blinking light". The
  Explained tab describes the light; no panel renders it.
- `Telephony.refresh_cost/2` — re-prices an unfinal Twilio row; no scheduler.
- `Music.Player.request_play/enqueue/toggle/next/seek` — an entire GenServer
  client API. `MusicPlayerLive` calls `Player.toggle/1` and `Player.seek/2`
  directly, bypassing all five.
- `Notifications.list_notifications/0`, `get_notification/1`
- `Integrations.latest_documents/1`
- `Calendar.get_event_by_event_id/1`
- `BrowserHistory.visit_count/1`, `visit_counts/1`
- `Appearance.background_mode/0`, `terminal_background_url/0`
- `Settings.reset_onboarding/0` — "run the wizard again"; nothing offers it
- `Orchestration.engage_kill_switch/0` — the STOP file is written by the CLI
  directly, not through this

**Parsers and formatters with no pipeline.** `Ingest.Content.parse_article/1`,
`parse_rss/1`, `Search.format_results/1`, `DispatchProjector.render_diary/1`,
`StreamEvent.run_usage/1`, `activity_state/1`, `activity_label/1`,
`Browser.Bridge.payload_contract/0`.

**Constants exposed for tests.** `ModelPolicy.unfloored_money_surfaces/0`,
`Finance.BLS.daily_quota/0`, `TerminalTheme.fixed_presets/0`,
`Music.total_bytes/0`, `Recovery.recovery_key/0`, and in the cut-up engine
`Mfcc.with_deltas/2`, `without_c0/1`, `Signal.hamming/1`.

### Orphaned files

- **Scripts nothing references** (not CI, not docs, not `mix.exs`, not another
  script): `scripts/gen_sounds.exs`, `scripts/install_launchd.sh`,
  `scripts/probe_codex_appserver.exs`, `scripts/probe_opencode_server.exs`,
  `scripts/smoke_chat_steering_codex.exs`,
  `scripts/smoke_chat_steering_opencode.exs`. The two smokes are the ones the
  chat-steering roadmap said "only the real-CLI smokes caught four defects" —
  they are valuable and undocumented, which is how they will be deleted by
  mistake.
- **One CSS utility with no user:** `.ic-vox-act` (28 `ic-` classes defined, 27
  used).
- **`lib/buster_claw.ex`** — generator placeholder, stock moduledoc.
- **No orphaned JS.** `tab_rename.js` is not imported by the hook index but is
  composed into `tab_strip.js`; `browser_pages.js` is a fourth esbuild entry
  point, wired in `config/config.exs:76`.
- **No orphaned tables.** The six tables left behind by the Trading and MCP
  deletions were all dropped by migration (`20260808070000`, `20260809160542`).

### The shipped brand art is not in the repo — found 09-06, during Phase 1

**This one is not a cleanup item. It is a packaging defect, and the review
missed it.**

`.gitignore:39` excludes `/priv/static/images/brand/` with the comment "Brand art
(wordmarks / logo / backgrounds) — local-only, kept out of the repo" — a
deliberate call made on 06-13 (`551b6fb`). But `Pockets.Brand` declares six
shipped defaults that point straight into that directory:

```
lib/buster_claw/pockets/brand.ex:96   default: "/images/brand/home-icon.png"
                              :103   .../workspace-icon.png
                              :110   .../browser-icon.png
                              :117   .../terminal-icon.png
                              :124   .../settings-icon.png
                              :131   .../buster-claw-heading.png
```

`git ls-files priv/static/images` returns **nothing**, and no script generates
these files. So a fresh clone has no navigation icons and no wordmark. The
packaged `.app` is built from a checkout, which means **the DMG that goes to R1
testers ships with six missing images** unless the builder happens to have them
sitting untracked, as this machine does.

`brand_test.exs:201` — "every shipped default is a real file in priv/static" —
is the test that already knows. It passes here only because the untracked files
exist in this working copy; it fails in any worktree built from committed
history, which is how Phase 1 stumbled over it. It carries no OS tag, so it has
been failing on the ubuntu CI runner too, sitting inside the red that was
attributed to macOS-only tooling. **A month of red CI hid a shipping bug**,
which is the same lesson `ci_green_after_a_month` already recorded once.

Three ways out, and the choice is the operator's because it is about asset
rights, not code:

1. **Track the art.** Delete the ignore line, commit the six PNGs. The test
   becomes true everywhere and the DMG is whole. Rejected once on 06-13, so the
   reason it was rejected needs restating before this is chosen.
2. **Keep it local and make the code honest.** The defaults become optional: a
   missing default renders a text wordmark or an empty slot, the test asserts
   the graceful path rather than the file, and `build_desktop.sh` gains a
   pre-flight that refuses to package without the art.
3. **Fetch it at build time** from wherever the art actually lives, with the
   build failing loudly when it cannot.

Doing nothing is the only option that is not available, because today the repo
says all three things at once: the art is excluded on purpose, required by a
test, and assumed present by the UI.

### Generated artifacts in two states at once

`desktop/tauri/.gitignore:4` ignores `/gen/schemas`. All four files under it are
**tracked anyway** (`git ls-files -i -c` lists them), last committed 08-08, and
**modified in the working tree** because `build.rs` has since gained
`list_voices` and `app_icon_set`. Meanwhile 38 of the 42 files under
`permissions/autogenerated/` are tracked and 4 (`app_icon_set`, `clinch_put`,
`clinch_delete`, `clinch_reveal_recovery_key`) are untracked. So a fresh `cargo
build` dirties the tree, `git status` has shown noise since 08-08, and CI cannot
assert that the committed ACL matches the built one because the committed one
is not meant to be committed. Pick one: track and assert, or ignore and
regenerate. Today it is both.

### Suppressed — small, and all written down

| Kind | Count | Notes |
|---|---|---|
| `# credo:disable` | 6 | `dispatcher.ex:152`, `commands.ex:508`, `file_manager.ex:49`, `gmail/mime.ex:198`,`:254`, `finance/edgar.ex:96`; every one has its reason on the line above |
| `@dialyzer` / `sobelow_skip` | 0 | |
| `@tag :skip` / `:pending` | 0 | |
| Credo checks disabled in config | 1 | `DuplicatedCode` (`.credo.exs:65`) |
| Credo thresholds relaxed | 2 | complexity 15, nesting 3, both with reasons |
| Dialyzer `unmatched_return` | rule | ignored everywhere except Clinch, Sentinel, Vault, Telephony — a deliberate baseline, restructured 08-13, with a written limitation (unreachable code is not analysed) |
| `rescue … -> nil / :ok / false / []` | 14 | `agent/chat.ex:803,1018,1469`, `terminal_commands.ex:80,315,398`, `browser_control/cdp.ex:255,261`, `agent_runner.ex:410`, `google/bundled_client.ex:119`, `orchestration/uptime.ex:141`, `cli.ex:329`, `setup_live.ex:662`, `google_oauth_controller.ex:115` |
| `Process.sleep` in `lib/` | 3 | `cdp.ex:213` (300 ms), `page.ex:232` (poll), `cli.ex:419` (watch interval) |
| `Process.sleep` in tests | 23 files | `AGENTS.md` forbids it; `swarm_test`, `dispatcher_test`, `agent_runner_test`, `pool_test`, `bridge_test`, `status_live_test` among them |
| Rust `#[allow]` | 2 | both `too_many_arguments`, `browser/mod.rs:63`, `webviews.rs:176` |
| Rust `unwrap()`/`expect()` outside tests | 5 | all `voice.rs:91–185`, mutex lock unwraps in the speaker thread — a poisoned lock panics the thread |

The 14 swallowing rescues are the one row worth a second look. Three are in
`chat.ex` and three in `terminal_commands.ex`; a `rescue _ -> nil` in a
GenServer that owns the chat queue is a place a wedge can hide, and the 09-05
render-queue wedge (`2612105`) was exactly a death that "stayed marked as
running forever".

### Doc drift found

One: the 09-05 summary says "219 → 213 commands". The catalog has **214**
(verified by loading it), the README says 214, and the drift check agrees. The
summary is off by one.

---

## Part III — Roadmap for fixes

Ordered by what unblocks what. Each phase names its gate, because this repo has
decomposed large files three times and been undone twice, and the lesson it
recorded is that "a number nobody checks is a number that drifts back".

### Phase 0 — Two decisions only the operator can make

Nothing below depends on these, but Phase 6 is shaped by the first.

1. **The cut-up exit date.** Is the engine leaving this quarter, this year, or
   is "spun off" aspirational? If it leaves, `sound.ex` is partitioned, not
   split (Phase 6). If it stays, the `Notifications` namespace gets a
   `BusterClaw.Audio` home and the split proceeds as LEFTOVERS describes.
2. **`AgentToolPolicy`: wire or delete.** Recommendation: wire. It is the
   cheapest available answer to the 08-22 review's Critical #1 for the
   Dispatcher path — pass `denied_builtins/0` as `--disallowedTools` on every
   confined run. Deleting it means deleting the one measured record that
   `WebFetch` reaches loopback.

### Phase 1 — Build hygiene (hours)

- **Generated Tauri artifacts: one state.** Either remove `/gen/schemas` from
  the ignore file, commit the four modified schemas and the four untracked
  TOMLs, and add a CI step that runs `cargo build` and fails on a dirty tree;
  or ignore both directories and delete them from the index. The first is
  better: it makes the ACL lockstep visible in diffs.
- Fix the 09-05 summary's command count (213 → 214).
- Delete `.ic-vox-act`.
- Add a one-line `scripts/README` or a `docs/QUALITY.md` section naming the six
  unreferenced scripts and what each is for, so the two steering smokes stop
  looking like litter.

**Gate:** CI step "generated files are committed" is red before the fix, green
after.

### Phase 2 — Dead code pass #2 (a day, using the 08-09 method)

Work the inventories in Part II with the three questions per item. Suggested
verdicts, to be confirmed item by item:

| Item | Verdict |
|---|---|
| `AgentToolPolicy` | **wire** (Phase 0) |
| `DataState` + its test | delete |
| `Dispatch.heartbeat/1` | **decide**: either the Dispatcher calls it on each tick and something reads staleness, or drop `heartbeat_at` from both schemas by migration. A column nobody writes is a lie the next reader will believe |
| `Telephony.unheard_count/0` | wire into the Phone tab (the Explained page already promises the light) |
| `Telephony.refresh_cost/2` | wire to a scheduled retry or delete |
| `Music.Player.request_*` (5) | delete; the LiveView already bypasses them |
| `TerminalCommands.reset_catalog/0`, `reset_role/1` | wire as a Settings affordance or delete |
| `StudioMix.clear_effects/2`, `Voice.Chimes.render_all/1`, `Voice.Greeting.rendered_path/0` | cut-up/voice owners decide; if the engine is leaving, `clear_effects` goes with it |
| `Settings.reset_onboarding/0`, `Orchestration.engage_kill_switch/0` | wire (a "run setup again" button; the CLI's STOP write should go through the context) or delete |
| the eight parsers/formatters, the eight test-exposed constants | delete, or make the test construct its own fixture |

**Gate:** the same corpus-index sweep re-run reports zero core functions in
"no caller, no internal use". Keep the sweep script in `scripts/` so the number
is re-checkable; do not turn it into a CI gate yet (it has HEEx false
positives).

### Phase 3 — Privatise the 92 (mechanical, a day)

Convert the 92 test-only-public helpers to `defp`, file by file, and move each
test to the public behaviour it was really checking. This is the highest-value
modularity change per hour in the review, because after it **the compiler
becomes the dead-code guard**: an unused `defp` fails `--warnings-as-errors`.

Two mandatory precautions from the 08-09 pass: (1) check `workspace.ex` and
`voice/renderer.ex` for `{__MODULE__, :fun}` registries before touching them;
(2) after the suite, **boot the app**, because seed registries run at boot and
the suite does not exercise them.

**Gate:** `mix compile --warnings-as-errors` and a real boot, both green; the
public-function count in `lib/` drops from 2,220 to roughly 2,130 and the size
gate is unchanged (this phase moves no lines).

### Phase 4 — Six duplicates (half a day)

Extract `html_entities` into `Ingest.Content` and have `Search` call it;
extract `build_match` into a shared FTS helper for `BrowserHistory` and
`Memory`; unify the two `rename` implementations under `Music`; collapse the
two Twilio `request` functions into `Telephony.Twilio`; the GitHub row pair and
the two codex normalisers are fine to leave with a comment.

**Gate:** re-enable `Credo.Check.Design.DuplicatedCode` with a mass threshold
that passes after the fix, so the seventh pair fails.

### Phase 5 — Web layer purity (half a day)

Move the nine `File.*` / `System.cmd` call sites out of the six web files into
the contexts that own the paths (`Workspace`, `Voice`, `Agent.Attachments`,
`BrowserControl`). **Gate:** a test asserting no file under
`lib/buster_claw_web` matches `System.cmd|File\.(read|write|rm|ls|mkdir)`,
modelled on the existing ACL lockstep test, and broken once on purpose before
it is trusted.

### Phase 6 — The frozen files (per file, one to three days each)

In order of return:

1. **`commands/sound.ex` (2,464) — partition, don't split.** Two modules: the
   four library verbs stay in `Commands.Sound`; the 26 cut-up verbs move to
   `Commands.Cutup` (or the name the spin-off uses). If Phase 0 says the engine
   leaves, the exit becomes `git rm` of one file plus 26 catalog lines. If it
   stays, this is the first cut LEFTOVERS asked for anyway.
2. **`agent/chat.ex` (1,510)** — the cut LEFTOVERS names: extract the queue and
   run-lifecycle half, leaving the GenServer around 900 lines. Write down the
   `:idle` split first (LEFTOVERS §5 has the note). Do not raise the cap.
3. **`commands/web.ex` (848, 52 public)** — after Phase 3 most of the 52 are
   `defp`; whatever remains public partitions by verb family (fetch/search,
   co-presence, agent mode).
4. **`AppearanceLive.render/1` (465)** and **`SetupLive.render/1` (292)** —
   extract one function component per region, by the rule the repo already
   proved: `import` the extracted module so template call sites stay
   byte-identical.
5. `tab_strip.js` (664) and `chrome.js` (864) — the JS half of the same
   promise; no proposal here beyond "they are on the list".

**Gate:** each file's cap in `check_file_sizes.sh` ratchets down in the same
commit as the cut; the gate fails on an under-cap file precisely so this
happens.

### Phase 7 — Test hygiene (a day, low urgency)

Replace the 23 `Process.sleep` sites in tests with `Process.monitor` and
`:sys.get_state` as `AGENTS.md` requires; silence the `:capture_confirmation`
crash report with `@tag :capture_log` or an expected-exit assertion; replace the
five `voice.rs` mutex unwraps with `lock().unwrap_or_else(PoisonError::into_inner)`
or an explicit `expect` message. **Gate:** `grep -c Process.sleep test/` is 0;
the suite prints no crash report.

### What this review did not do

It did not run the packaged app or walk any surface; the 08-22 review's
runtime findings are not re-verified here. It did not re-review security. And
every "no caller" claim is a grep-class claim, which this repo has already
learned is a lower bound — that is why Phase 2 is a pass with three questions,
not a delete list.
