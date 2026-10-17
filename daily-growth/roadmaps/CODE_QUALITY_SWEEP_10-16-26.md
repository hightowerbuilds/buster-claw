# Code quality sweep — 2026-10-16

**Scoped 10-16-26; all ten phases BUILT the same day** (nine commits, `c01c713` → Phase 10). Operator's ask: *"run an entire sweep of the entire app for
code quality — pick out sections we can modularize to be stronger, more
structurally integral code, and remove all the dead, orphan and suppressed code
or anything related to features that no longer exist. Write a map, then follow
through with the refactor."*

**Snapshot:** `c3c65f5` (main, clean). Every gate green: `mix precommit` at
3,281 Elixir tests + 371 JS tests, cycles 2 accepted, size inventory holds,
Rust fmt/clippy/test clean. Dialyzer and sobelow gate CI.

**Method.** Tooling first, reading second, the same discipline as the 09-05
review: a whole-corpus reference scan (modules with no caller in `lib/`, public
functions with no caller outside their file, test-only publics), a leftover-word
sweep for every feature ever removed, a suppression census, a clause-length
scan, a hook↔markup, CSS↔markup, script↔reference and static↔reference check,
config-key↔reader check, the Rust tree, and the test suite's hygiene numbers.
Scan output: `scratchpad/refs.txt` (session), reproduced in the Appendix.

> ### What shipped, and what the build corrected in this map
>
> **Phase 1** (`c01c713`): the contact-faces stack whole (migration, modules,
> two shaders, palette), `clear_effects`, the dead trading config key, four CSS
> classes, fourteen tracked digests + the ignore gap, the placeholder module,
> two comments. **Phase 2** (`6f91b04`): five zero-caller functions;
> `scripts/refs_scan.py` checked in. **Phases 3–4** (`6fbbc01`): `CLI.Format`
> extracted (cli.ex 960 → 705); four test-only publics deleted with their
> tests; `Sound.rename_file/5` and `BusterClaw.FTS.match/1` replace the two
> duplicate bodies. **Phase 5** (`5789e92`): five web-layer writes moved into
> `Sound`, `Workspace`, `Browser`, `SoundStudio`, `Attachments`; the purity
> lockstep test, broken once on purpose. **Phase 6**: `Commands.Sound` →
> `Sound.{Library,Edit,Shared}` behind a facade (1,086 → 114 + 557 + 323 + 163);
> `Commands.Web` → `Web.{Tab,Checks,Bookmarks,Secrets,Fetch}` behind a facade
> (848 FROZEN → 50 + 521 + 145 + 82 + 80 + 52) — the first freeze lifted by
> extraction. The cycle gate still reads 2.
>
> **Corrections the build made to this map:** `ModelPolicy.unfloored_money_
> surfaces/0` stays — it is a deliberately non-vacuous guard with its reasoning
> in code and test (08-09), not trading residue. `Contacts.delete_contact/1`
> stays — its test pins that deleting never revokes trust. `Mounts.valid_name?`
> and `Capture.recorder_available?` stay as a lockstep contract and a test gate.
> The "268-line `normalize_args`" was a scan artifact of the CRUD macro's
> indentation; the function is eight lines, so no `Commands.Args`.
> `AgentBackend.plausible_model?/2` has no production caller — wire it into the
> model picker or delete it (added to Q6).
>
> **Phases 7–10, built in the evening** (`0e35821`, `d5530f2`, `3a32719`, and
> the Phase 10 commit). **Phase 7:** six page-sized renders became function
> components by the purity rule — `AppearanceLive` (1,064 → 466; the
> EXTRACTION OWED since 08-15 paid: `components/appearance/{catalog, look,
> terminal_palette}`), `SetupLive` (684 → 350; `components/setup/steps.ex`, one
> component per step), `Settings.ModelsComponent` (463 → 232;
> `components/settings/models.ex`), `BrowseLive` (455 → 299;
> `browser/agent_watch.ex`, the activity bar into `activity_graph.ex`),
> `ChatPanel` (1,001 → 481; `chat_panel/{bubbles, composer}.ex` — the cut its
> own cap note named, with the skin contract now held by the compiler), and
> `BrowserChromeController.page/3` (a 270-line heredoc → `browser/chrome_page.ex`,
> HEEx, for the reason `Browser.Layout` gives). Every LiveView test's
> assertions unchanged; three source-reading lockstep tests repointed at the
> file the text moved to. **Phase 8:** `chrome.js` 854 → 605 (`lib/chrome_bar.js`,
> one strip with one explicit mode where there were two flags, and
> `lib/chrome_downloads.js`), `tab_strip.js` 511 → 307 (`hooks/tab_menu.js`,
> `hooks/tab_close_confirm.js`); both freezes lifted to HELD. Rust:
> `browser/agent.rs` (the eleven co-presence commands, 934 → 570 in `mod.rs`),
> `menu.rs` (837 → 680 in `main.rs`). `note_editor.js` kept on purpose — its cap
> note says the logic is already out and the essay is load-bearing. The
> packaged smoke of the chrome was not run; the dev app rebuilt on the new Rust
> and the bar's three modes were walked in Chrome. **Phase 9:**
> `status_live_test.exs` 2,044 → four files on `test/support/home_case.ex`
> (shell · chat · Explained · Notify); `StatusLive`'s two widget seams took
> their hosts (`status/comms.ex` gained the three trust verbs,
> `status/notify.ex` is new; 773 → 696). `Process.sleep`/`Process.alive?` **44
> → 25**, not 0: the 19 rewritten had an honest equivalent (`:sys.get_state`
> where "alive" meant "answering", a monitor + DOWN where a session must be
> gone, `render/1` where a view must be up, three `alive?(self())`
> tautologies, a dead poller, two cleanup guards that were already no-ops).
> The 25 that stay each poll a side effect nothing can sync on — a Task's
> database write (`dispatcher_test`, `model_policy_wiring_test`), an OS
> process's pid file or JSONL line (`agent_runner_test`,
> `chat_attachment_wiring_test`), a DOWN a server receives concurrently
> (`bridge_test`, `pool_test`), an mtime boundary (`dispatch_projector_test`)
> — or are fake slow work (`swarm_test`, `capture_test`), or live in the
> `:browser_engine`-tagged real-Chromium tests this machine does not run
> (`window_placement`, `screencast`, `page_targeting`, `pool_live`). The gate
> in Part V said 0; this is the corrected number and its reasons. Three
> pre-existing test-compile warnings fixed. **Phase 10 (Q2 = yes):**
> `BusterClaw.Studio.{Editor, Mix, Catalog, Capture, Effects, Render}` under
> `lib/buster_claw/studio/` (was `Notifications.{SoundStudio, StudioMix,
> StudioCatalog, Capture, Studio.*}`); `Notifications.Sound`, `SoundGen` and
> `SoundBoard` stay, because they are the chimes. 35 files, no behaviour,
> cycles still 2. `Studio.Mix` shadows Elixir's `Mix` inside the files that
> alias it; none of them touch build tooling and a collision is a loud
> compile error, so the honest name won. **Still open:** `Agent.Chat`'s split
> (measure clause ownership first), Q6, and the 09-05 review's Phases 3–7 as
> re-measured here.

> ### The one-sentence version
>
> **The architecture is still modular and the gates still hold; what has rotted
> since 09-05 is the residue of four whole-feature deletions (cut-up, Vox, Sketch
> Pad, phone) — an orphaned faces stack, two dead shaders, a dead config key,
> fourteen build artifacts in git, comments naming things that no longer exist —
> plus the three structural debts the 09-05 review named and nobody paid: the
> frozen files, the 82 helpers made public to be tested, and the web layer's
> file-system calls, which grew from nine sites to sixteen.**

> ### Read this first: what this map inherits, and the standing DON'Ts
>
> Three quality passes precede this one and their decisions stand:
> `CODE_QUALITY_ROADMAP` (07-17, archived), `CODE_QUALITY_REFACTOR_ROADMAP`
> (08-02; 3B/3C/4 still open), the dead-code pass (08-09, archived) and the
> `CODE_REVIEW_09-05-26` roadmap (Phases 0–2 done; **3–7 open**). This map
> re-measures their open items rather than restating them, and adds what four
> deletions left behind. **Do not re-propose:** breaking the two accepted
> dependency cycles (web ring, Google facade); a `_ = …` sweep over unmatched
> returns; a daisyUI migration as a refactor; a native-command registry; the
> 260-comment archaeology sweep. **Do apply:** the 08-09 lessons — a grep
> inventory is a lower bound; `{__MODULE__, :fun}` registries and
> `seed: {mod, fun}` entries are invisible to grep AND to
> `--warnings-as-errors`; a docstring naming a caller is not a caller; after
> every deletion phase, **boot the app**, because seed registries run at boot and
> the suite does not exercise them.

---

## Contents

- [Part I — Dead, orphaned, leftover](#part-i--dead-orphaned-leftover)
- [Part II — Suppressed](#part-ii--suppressed)
- [Part III — Where it can be more structurally integral](#part-iii--where-it-can-be-more-structurally-integral)
- [Part IV — Decisions](#part-iv--decisions)
- [Part V — Phases and gates](#part-v--phases-and-gates)
- [Part VI — Open questions for the operator](#part-vi--open-questions-for-the-operator)
- [Appendix — The numbers](#appendix--the-numbers)

---

## Part I — Dead, orphaned, leftover

### I.1 — Residue of removed features (verdict per item)

| Feature | What is still in the tree | Verdict |
|---|---|---|
| **Phone** (removed 10-15) | `Contact.face_shader` / `face_seed` columns and `Pockets.Faces` (**no renderer anywhere in `lib/buster_claw_web`** — the only readers are the module itself and, until this morning, the Explained prose); `Shaders.face?/1` and `ShaderApproval`'s face rejection; `assets/js/smoke/face.wgsl.js`, `keypad.wgsl.js`, the `keypad` palette in `palettes.js`, the "BusterPhone keypad" comment in `sevenseg_glyphs.wgsl.js`; `config/runtime.exs:73-75` comment block describing the relay drain; `Contact.phone` column + E.164 `normalize/1`; `WorkbenchState.@retired_keys ["phone"]`; `Jobs.@retired_jobs`; `messages_probe` Twilio sentence (fixed this morning) | **Delete the faces stack whole** (D2): columns by forward migration, `Pockets.Faces`, `Shaders.face?`, the approval reject, the two WGSL files, the palette, the comment. **Keep** `Contact.phone` (a fact about a person, Q4), the retired-key and retired-job lists (they ARE the upgrade path), `sevenseg` (the shader timer uses it). Rewrite the runtime.exs comment. |
| **Trading** (removed 08-08) | `config/test.exs:84 portfolio_recorder_enabled` — no reader anywhere; `ModelPolicy.@floors %{}` + `unfloored_money_surfaces/0` + `capability_rank/1` (test-only); comments naming Robinhood in `agent/conversation.ex`, `model_policy.ex`, `chat.ex`, `chat.js`, `composer.js`, `split.js`, `compose_keys.js`; `Workspace` deprecated entries `trading/` | Delete the config key. **Keep the floor mechanism** (08-02 decision: "the next money-shaped surface should not reinvent it") but drop `unfloored_money_surfaces/0` and its vacuous test. Leave comments that explain a shape; rewrite the ones that promise a surface. Workspace deprecated entries stay (they are the sweep list). |
| **Cut-up engine** (removed 09-19) | `StudioMix.clear_effects/2` (09-05: "if the engine is leaving, `clear_effects` goes with it" — it left; still here); `Studio.Effects` "cut-up" comment; `catalog/sound.ex`, `commands/sound.ex`, `sound_capture.ex`, `seed.ex`, `skills.ex` mentions | Delete `clear_effects/2`. Comments: keep the ones recording a deletion, rewrite the ones describing a live thing. |
| **Vox / VoxCPM** (removed 10-11) | `assets/js/lib/retired_tabs.js` recovers `/voice` tabs; `LegacyVoiceController` redirects `/voice`; `Notifications.Capture` "whisper" comment | **Keep both recoveries one more release** (Q3) — they are what an upgraded install's saved tabs hit. The comment is history; leave. |
| **Sketch Pad** (removed 09-05) | `commands.ex` and `svg_viewer.ex` mentions; `Workspace` deprecated `sketches/` | History + sweep list. Keep. |
| **Cmd List page** (removed 09-05) | `LegacySettingsController` redirects `/cmd-list` | Same as `/voice` (Q3). |
| **Dock → sidebar** (10-14) | `layouts.ex` `/phone` label (fixed this morning); `MusicController` doc says "for the dock player" — the player left the dock 09-13, the route now serves the Studio's Music group | Rewrite the moduledoc. Route stays (live caller: `sound_studio/catalog.ex`). |

### I.2 — Orphaned modules

The reference scan flags 77 modules with zero references from other `lib`
modules; **almost all are false positives** (controllers and LiveViews reached
through the router's scope alias, catalog modules reached as `Catalog.X`,
transports chosen by atom). Verified by hand, the real list is short:

| Module | Finding | Verdict |
|---|---|---|
| `BusterClaw.Search` | one caller (`Commands.Web.search/2`); its `format_results/1`, `parse_results/1` are test-only | Keep; privatise the two (I.3). |
| `BusterClaw.DutyActivity` | one caller (`DutyLive`) | Keep — it is a context with one surface. |
| `Mix.Tasks.Messages.Probe` | no `lib` caller (a mix task); the iMessage probe is the likely phone successor (`IMESSAGE_ROADMAP`) | Keep. |
| `BusterClawWeb.DevMicProbeController` | dev-only route | Keep. |
| `BusterClawWeb.OlympusLive` + `olympus.js` + `olympus.css` (48 lines) | arrived 10-12 in `157750d`; no roadmap names it; reached only by `/olympus` | **Not dead — new.** Needs a map row and a sidebar door or a deletion date, which is the operator's (Q5). |
| `lib/buster_claw.ex` | the generator's placeholder, stock moduledoc, 9 lines | Replace with the real thing: a moduledoc that names the contexts (the map of `lib/buster_claw/` a reader lands on). |

### I.3 — Public functions with no caller

From the scan (names ending in `?` were unreliable in the scan and are
excluded until verified by hand):

- **28 public functions called by nothing outside their file and not used by a
  test either.** Candidates for deletion or `defp`, each to be verified with the
  three 08-09 questions (dynamic caller? registry seed? CLI/API surface?).
  Named: `AttentionContract.apply?`, `Chat.running?`, `Clinch.Vault.encrypt!/
  decrypt!/ciphertext?`, `Dispatch.any_untrusted_open?`, `GmailAttachments.
  default_dir`, `Introduction.install!` (called via `ensure/0` in-file),
  `Pages.install!`, `Messages.bundled_binary`, `RuntimeConfig.release?/
  secret_key_base!`, `StudioMix.clear_effects`, `Calendar.get_event!`,
  `Library.get_document!`, `Notifications.get_notification!`, `Integrations.
  get_integration!`, `Google.get_account!`, `Contacts.get_contact!` (the bang
  getters are generator habit — nothing raises on them), `Screencast.
  handle_continue` (a callback; false positive), `Application.config_change`
  (callback; false positive).
- **82 public functions whose only outside caller is a test** (09-05 counted
  125, then 92 after its own pass; four deletions since took more). Densest:
  `cli.ex` 10 (`format_*`, `connection_message`, `request_timeout_ms`),
  `agent_backend.ex` 4, `notifications/capture.ex` 4, `commerce/cart.ex` 3,
  `calendar/grid.ex` 2, `browser/bridge.ex` 2, `dispatch_projector.ex` 2,
  `ingest/content.ex` 2, `search.ex` 2, `notifications/schedule.ex` 2.
  **This is the 09-05 Phase 3 debt, unpaid.** The fix is not 82 `defp`s: where a
  cluster is a real seam (`CLI.format_*`), it becomes a module with a real public
  interface and its test becomes a test of that module; where it is a helper, it
  becomes `defp` and the test moves to the behaviour. After that **the compiler
  is the dead-code guard** (`--warnings-as-errors` flags an unused `defp`).

### I.4 — Assets, config, artifacts

| Item | Finding | Verdict |
|---|---|---|
| CSS | 4 `ic-` classes defined and used nowhere: `ic-dot`, `ic-glass` (`app.css`), `ic-workbench-hint`, `ic-workbench-tools` (`workbench.css`, incl. a media-query rule) | Delete. |
| JS | no orphan hooks (every registered hook has a `phx-hook`); no orphan lib module (`browser_activity_model.js` is imported by the view) | — |
| Shaders | `face.wgsl.js`, `keypad.wgsl.js` registered in `smoke/shaders.js` and offered nowhere; `keypad` palette | Delete (I.1). `sevenseg` stays. |
| Static | **14 digested font copies are tracked in git** (`priv/static/fonts/*-<hash>.woff2`) — `.gitignore` covers `*-*.ico`, `*-*.txt`, `sounds/*-*.wav` and not `fonts/`. `phx.digest` output in the index is a drift source every release. | `git rm --cached` the 14, add `/priv/static/fonts/*-*.woff2` to `.gitignore`. |
| Static | `images/brand/` is ignored; three local files there (`home-bg.jpg`, `busterclaw-logo.png`, `calendar-icon.png`) are referenced by nothing | Local-only; note it in `LAUNCH_ROADMAP`'s brand-art item, nothing to commit. |
| Config | `portfolio_recorder_enabled` (test.exs) has no reader | Delete. |
| Config | `agent_chat_audit`, `agent_chat_persist`, `google_bundled_client`, `terminal_api_token`, `finnhub_api_key` | All read (the scan's pattern missed `get_env(:buster_claw)[:key]` forms). Keep. |
| Scripts | every script is referenced (09-05 Phase 1 fixed this) | — |
| Mix deps | `earmark`, `html_sanitize_ex` each have callers; `deps.unlock --check-unused` is green | — |

### I.5 — Dialyzer, Rust, tests

- **Rust:** 5,255 lines, two `clippy::too_many_arguments` allows (both
  justified in place), no `dead_code` allows, no feature leftovers. Clean.
- **Tests:** 300 files; 144 `async: false`; **20 `Process.sleep` and 24
  `Process.alive?` sites** in a repo whose `AGENTS.md` forbids both;
  `status_live_test.exs` at 2,044 lines holds every home-panel test. The
  retired-feature words in twelve test files are all history comments or
  retirement guards, not tests of dead code.

---

## Part II — Suppressed

The best result in the sweep, as it was on 09-05:

- **9 `credo:disable` lines** across 7 files (`Nesting` ×3,
  `CyclomaticComplexity` ×3, `UnsafeToAtom` ×1), each beside the thing it
  suppresses with a reason. `DuplicatedCode` is **enabled** (`.credo.exs:193`).
- **Dialyzer:** the 08-13 baseline is a *rule* (`unmatched_return` ignored
  except on the gated security/persistence paths), not a file list. Nothing to
  do.
- **No `@tag :skip`, no `@moduletag :skip`, no `TODO`/`FIXME`/`HACK`, no
  `rescue _`, no `catch _, _`** anywhere in `lib/` or `test/`.
- **JS:** 13 `catch {}` swallows, all in hooks around `localStorage` /
  `sessionStorage` / `setPointerCapture` — the documented pattern for storage
  that may be disabled. Acceptable; each carries a comment.
- **`@moduledoc false`:** 6, all on internal web components.

Verdict: nothing to remove. Part II is a census, not a phase.

---

## Part III — Where it can be more structurally integral

Measured now (lines; clause-group length for functions):

### III.1 — The frozen files, still frozen, still too big

| File | Lines | Shape | Proposed seam |
|---|---|---|---|
| `lib/buster_claw/agent/chat.ex` | 1,510 | one GenServer: queue + run lifecycle + transport routing + attachments hand-off | `Agent.Chat` keeps the GenServer and its API; **`Chat.Queue`** (the turn queue and its drain), **`Chat.Run`** (start/stream/finish/interrupt), **`Chat.Transports`** (choose transport by backend; the six `ChatTransport.*` modules already exist, the routing lives here). Measure clause ownership before cutting. |
| `lib/buster_claw/commands/sound.ex` | 1,086 (22 public, 71 private) | post-cut-up it is still two things: the library verbs (`list`, `routes`, `sources`, `probe`, `apply`, `restore_defaults`, `delete`) and the studio edit verbs (`import`, `trim`, `fade`, `normalize`, `concat`); capture already lives in `sound_capture.ex` | **`Commands.Sound.Library`** and **`Commands.Sound.Edit`**, with `Commands.Sound` as the catalog facade. The 09-05 "sharpest move" — now that the engine is gone the cut is small. |
| `lib/buster_claw/commands/web.ex` | 848 (52 public) + `catalog/web.ex` 600 | fetch/search/bookmarks/history, live-tab verbs, checks/flows, egress | `Commands.Web.{Fetch, Tab, Checks, Egress}`; catalog stays one file (it is data). |
| `assets/js/chrome.js` | 854 | omnibox, tab strip glue, menus, downloads, find | `chrome/{omnibox,menus,find,downloads}.js` — 09-05 Phase 6, part landed 09-13 (`chrome_app_tabs.js`). |
| `assets/js/hooks/tab_strip.js` | 511 | | same phase; `tab_rename.js` already split out. |

### III.2 — Render functions that are whole pages

| Function | Lines | Seam |
|---|---|---|
| `AppearanceLive.render/1` | 477 | four regions — mode picker, shader catalog, image slots, per-surface palette — → four function components under `components/appearance/`. The `SurfacePanel` component (125) already shows the shape. |
| `SetupLive.render/1` | 300 | one component per wizard step. |
| `Settings.ModelsComponent.render/1` | 239 | harness picker / per-surface rows / model lists. |
| `BrowseLive.render/1` | 226 | chrome frame / activity graph / agent-mode mirror. |
| `SettingsLive.render/1` | 218; `NotifySettingsLive.render/1` 198; `IntegrationsLive.render/1` 187; `CalendarComponent.render/1` 173 | same treatment, lower priority. |
| `ChatPanel.chat_panel/1` 172 + `chat_tabs/1` 121 + `composer/1` 108 in a 1,001-line component file | `chat_panel/{tabs,composer,transcript}.ex`. |
| `Commands.normalize_args/2` 268 + the 229-line `unquote` block in `commands.ex` (757) | **`Commands.Args`** — argument coercion is a pure, testable module hiding inside the dispatcher. |
| `BrowserChromeController.page/3` | 274 | the chrome HTML is a template; move it to a `.html.heex` or a component. |
| The Explained panels (373 / 321 / 303 / 297 / 293 / 281) | content by design (08-08 ruling); not on this list. |

### III.3 — Seams the public surface hides

- **`cli.ex` (960):** ten `format_*` helpers public for tests → **`CLI.Format`**,
  a module whose public interface is honest and whose test is a real test.
- **`agent_backend.ex` (585):** four test-only publics (`attachment_flag`,
  `model_namespace`, `reports_usage`, …) → `defp`; the table they read is the
  module's own.
- **Duplicate bodies (09-05 found six; two remain and both drift silently):**
  `Music.rename/2` ≡ `SoundStudio.rename/2` (315 tokens) → one
  `AudioName.rename/3` taking the directory; `BrowserHistory.build_match/1` ≡
  `Memory.build_match/1` (238) → `BusterClaw.FTS.match/1`. (`html_entities`
  was already unified; the codex normalisers are rightly separate.)

### III.4 — Web layer doing file work

**16 `File.*` call sites in 10 files under `lib/buster_claw_web`** (09-05: nine
in six). `studio/preview.ex`, `range_response.ex`, `notify_settings_live.ex`
(`mkdir_p` + `cp!` of an upload), `workspace_live.ex` ×4 (`stat`, `mkdir_p`,
`write`), `status/chat_attachments.ex` (`read`), `sound_studio_component.ex` ×2,
`workspace_file_controller.ex`, `browser_screenshot_controller.ex`
(`mkdir_p` + `write`), `appearance_controller.ex`, `pocket_asset_controller.ex`.
Each is a path the Sentinel layer and the workspace registry cannot see. The
`stat` calls behind range responses are arguably presentation; the writes are
not. Fix: move the writes into the contexts that own the paths (`Workspace`,
`Notifications.Sound`, `Agent.Attachments`, `Browser`), then a lockstep test
asserting no file under `lib/buster_claw_web` matches `System\.cmd|File\.(write|
cp|rm|mkdir)`, broken once on purpose.

### III.5 — Namespace honesty

`BusterClaw.Notifications` holds timers and chimes **and** `SoundStudio`,
`StudioMix`, `StudioCatalog`, `SoundGen`, `Capture`, `Studio.*` — the whole
Sound Studio, ~3,500 lines that are a DSP workshop, not notifications. Move to
**`BusterClaw.Studio.*`** (Q2). It is a rename with wide test fallout and no
behaviour change, so it is its own phase at the end, or not at all.

### III.6 — LiveViews with wide event surfaces

`StatusLive` 37 `handle_event` clauses (the `status/` split already carries
chat and attachments; the widget's Contacts/Notify events and the workbench's
are the next two seams — `WorkbenchHook` exists, the Contacts events don't have
a host yet), `SoundStudioComponent` 33, `NotesComponent` 22, `SettingsLive` 18,
`StudioLive` 17. The pattern that worked (`trading_live_purity_extraction`,
08-02): map lines-per-responsibility, extract with `import` so call sites stay
identical, measure before and after.

### III.7 — Test hygiene

`status_live_test.exs` (2,044) → one file per home panel; the 20
`Process.sleep` and 24 `Process.alive?` sites → `Process.monitor` / `:sys.get_
state`, per `AGENTS.md`; the 144 `async: false` files are mostly honest (they
touch the workspace on disk) — not a target.

---

## Part IV — Decisions

- **D1 — Delete by the three questions, then boot.** For every candidate: is
  there a dynamic caller (`apply`, `{mod, fun}` registry, `seed:` entry, CLI
  verb, API route)? Does a test exercise behaviour that only exists through it?
  Is it a shipped surface someone's saved state can reach? Three noes → delete.
  After each deletion phase: `mix precommit`, then **boot the dev app and watch
  the seed log**, because that is where the 08-09 pass found what the suite
  could not.
- **D2 — The contact-faces stack goes whole.** No renderer has existed since
  the Phone tab left; a column nobody reads is a lie the next reader believes
  (the 09-05 heartbeat lesson). Forward migration dropping `face_shader` and
  `face_seed`; `Pockets.Faces` deleted; `Shaders.face?/1` and the approval
  reject deleted; the `face` naming rule leaves the Shaders tutorial; the two
  WGSL files and the palette go; `contact-faces` leaves the workspace seed list
  and joins `:deprecated` so an empty folder is swept.
- **D3 — Public means called.** A `def` with no caller outside its file is
  `defp`, and the test that reached it moves to the behaviour it was really
  checking — except where the cluster is a real seam, which becomes a module
  (`CLI.Format`, `Commands.Args`). This is how the compiler becomes the
  dead-code guard; it is the highest-value structural change per hour here.
- **D4 — Caps move in the same commit, both directions.** A file that shrinks
  banks its cap; a file that grows says why in the commit. No freeze is lifted
  without an extraction first (the LEFTOVERS rule for `chat.ex`).
- **D5 — Comments that record a deletion stay; comments that describe a dead
  thing as live are rewritten.** This is the Explained lesson applied to code:
  prose is the repo's least reliable index, and a comment promising a surface
  is drift.
- **D6 — Renames last, and only if yes.** The `Notifications → Studio` move is
  behaviour-free and touches the most files; it runs after every deletion and
  split, so it renames the smaller tree, and only on Q2.
- **D7 — Build artifacts leave the index.** The 14 digested fonts are
  `phx.digest` output; the `.gitignore` gap that let them in is closed in the
  same commit.
- **D8 — Legacy redirects get a date, not a deletion.** `/voice` and
  `/cmd-list` redirects and `retired_tabs.js` are the upgrade path for saved
  tabs; they leave one release after the next signed DMG (Q3).

---

## Part V — Phases and gates

Each phase is a commit (or a few), each ends with `mix precommit` green, a boot
of the dev app, and the caps rebalanced. Order is by value-per-risk: deletions
first (they shrink what every later phase has to move), splits second, renames
last.

| Phase | Scope | Gate |
|---|---|---|
| **0** | This map. | — |
| **1 — Leftovers** | D2 faces stack (migration, modules, shaders, palette, seed); `clear_effects/2`; `unfloored_money_surfaces/0` + test; `portfolio_recorder_enabled`; 4 CSS classes; 14 tracked digests + `.gitignore`; `lib/buster_claw.ex` moduledoc; `MusicController` and `runtime.exs` comments; the Rust tree needs nothing. | precommit; boot; `contact-faces` seed lockstep test updated; the Pockets tutorial already does not name it. |
| **2 — Orphans** | The 28 zero-caller publics and the bang getters, each through D1; `Search.format_results/parse_results`; `GmailAttachments.default_dir`; `Messages.bundled_binary`; `RuntimeConfig.release?`. | precommit; a re-run of `refs.py` reports zero non-predicate publics in "no caller, no test"; keep the script in `scripts/` as `scripts/refs_scan.py` (not a gate — HEEx false positives). |
| **3 — Privatise the 82** | D3, file by file; `CLI.Format` and `Commands.Args` extracted as real modules where the cluster is a seam; tests moved to behaviour. Check `workspace.ex` for `seed:` registries before touching anything it names. | precommit; `--warnings-as-errors` green; boot; public-function count in `lib/` drops by roughly 70; size gate unchanged (moves no lines). |
| **4 — Duplicates** | `AudioName.rename/3`; `BusterClaw.FTS.match/1`. | precommit; `Credo.Check.Design.DuplicatedCode` mass threshold lowered until it would catch a third pair. |
| **5 — Web purity** | III.4: the write sites move into contexts; the lockstep test lands and is broken once. | the test, red then green; precommit. |
| **6 — Partitions** | `Commands.Sound.{Library,Edit}`; `Commands.Web.{Fetch,Tab,Checks,Egress}`; `Agent.Chat.{Queue,Run,Transports}` (measure first; `chat.ex` FROZEN cap drops to the facade's size). | precommit; the catalog contract tests unchanged; the real-CLI chat smoke (`scripts/smoke_chat_steering_*`) run once by hand — it is the one that caught four defects last time. |
| **7 — Render decomposition** | `AppearanceLive`, `SetupLive`, `ModelsComponent`, `BrowseLive`, `ChatPanel`, `BrowserChromeController.page/3`; then `SettingsLive`, `NotifySettingsLive`, `IntegrationsLive`. Purity-extraction method; `import` so call sites stay identical. | precommit; each LiveView's test file unchanged in assertions; a Chrome walk of each page. |
| **8 — JS and Rust** | `chrome.js` → `chrome/*`; `tab_strip.js`; `note_editor.js` (560); Rust `main.rs` menu → `menu.rs`, `browser/mod.rs` commands → `browser/commands.rs`. | `bun test`; `check_rust.sh`; FROZEN caps become HELD caps on the pieces; packaged smoke of the browser chrome. |
| **9 — Test hygiene** | `status_live_test.exs` split by panel; `Process.sleep` / `Process.alive?` sites rewritten; `StatusLive` Contacts events get a host (`Status.Comms`). | precommit; the 44 sites → 0. |
| **10 — Namespace** | `Notifications.*Studio*` → `Studio.*` on Q2 = yes. | precommit; `check_cycles.sh` still 2; grep for the old names returns only history. |

---

## Part VI — Open questions for the operator

### Q1 — How much to invest in the Studio?

It is "experimental" by its own tutorial, ~3,500 lines of DSP plus a 973-line
component with 33 events, and the 08-02 roadmap's 3B (template decomposition)
has been open for ten weeks. Phases 6–7 touch it only where the seam is cheap
(the `sound.ex` partition). **Default: that much and no more** until the Studio
stops changing shape.

### Q2 — Move the Sound Studio out of `Notifications`?

A behaviour-free rename touching ~40 files and their tests. **Default: yes,
last** (Phase 10), because every reader of `lib/buster_claw/notifications/` is
misled today.

### Q3 — When do the legacy redirects go?

`/voice`, `/cmd-list`, `retired_tabs.js`. **Default: one release after the next
signed DMG**, recorded in `LAUNCH_ROADMAP`.

### Q4 — Does a contact keep its phone number?

The column, `normalize/1` and the Contacts tab's field. **Default: keep** — the
phone removal map's Q3 said so (a fact about a person), and the Google Contacts
sync writes it.

### Q6 — `AgentBackend.plausible_model?/2`

Tested, pure, and called by nothing in production: the model picker does not
validate plausibility. **Default: wire it** into `ModelPolicy.put_model` so a
model name the harness cannot recognise is refused at the setting rather than
on the next run.

### Q5 — Olympus

`OlympusLive` arrived 10-12 with no map, no sidebar door, and no test. It is
either the next surface or an experiment that should carry a date. **Default:
leave it, add a SUPERMAP row saying so.**

---

## Appendix — The numbers

| Measure | 09-05 | 10-16 |
|---|---|---|
| Elixir (`lib/`, git-tracked lines) | ~150k incl. cut-up | 83,929 (`.ex`) + 62,099 (`.exs`) |
| JS / CSS / Rust | 12.2k / 1.2k / 4.8k | 16,833 / 1,577 / 5,255 |
| Tests | 3,514 | 3,281 Elixir + 371 JS |
| Public functions, no caller but a test | 125 → 92 | 82 |
| Public functions, no caller at all (non-predicate) | 33 | 28 |
| Web-layer `File.*`/`System.cmd` sites | 9 in 6 files | 16 in 10 files |
| Frozen files | 6 | 4 (`chat.ex`, `commands/web.ex`, `chrome.js`, `tab_strip.js`) |
| Duplicate bodies | 6 | 2 |
| `credo:disable` | 9 | 9 |
| Unused `ic-` classes | 1 | 4 |
| Tracked build artifacts | 8 Tauri | 14 digested fonts |
| Largest files | `sound.ex` 2,464 | `chat.ex` 1,510 · `app.css` 1,229 · `sound.ex` 1,086 · `appearance_live.ex` 1,064 · `chat_panel.ex` 1,001 |
| Longest clause groups | `phone_panel` 547 | `AppearanceLive.render` 477 · `cmd_panel` 373 · `arranger` 318 · `SetupLive.render` 300 · `normalize_args` 268 |

The scan (`refs.py`) and its output live in the session scratchpad; Phase 2
checks the script in as `scripts/refs_scan.py` so the number is re-checkable.
