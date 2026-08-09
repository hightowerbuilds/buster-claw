# Dead code, orphans, and suppressions — a measured inventory

**Reviewed 2026-08-09 · Status: CLOSED + ARCHIVED 2026-08-09.** · **Scope:** how
big the codebase is, and what in it is dead, orphaned, over-exposed, or
suppressed.

> # CLOSED 08-09-26
>
> **F1–F8 are done. F9 is measured and leaves as its own roadmap.** Final state:
> compile `--warnings-as-errors`, `format --check-formatted`, `credo --strict`,
> **3,569 Elixir tests + 263 JS tests, 0 failures**, cycles, file sizes, docs
> drift and Rust all green.
>
> **What went:** 22 functions deleted, 47 made private, 10 CSS rules, 1 JS const,
> 6 JS exports narrowed, 2 database columns/tables (`mcp_servers`,
> `agent_conversations.docked`), 2 stale Dialyzer entries.
>
> **What arrived instead — the part worth reading.** Four things were *not*
> deleted, because tracing showed deletion was the wrong fix: a **seed-registry
> lockstep guard** now asserts 11 `{module, fun}` contracts that no grep and no
> compiler could see; a **byte-identity test** now backs the diary's append-only
> optimisation, which claimed an oracle it never had; a **non-vacuous floor
> guard** replaced a docstring promising a test that did not exist; and
> **`Clinch` now derives its write boundary** from one list instead of stating it
> in four places.
>
> **Three findings were wrong and their corrections are the value here** — §4b.
> The sharpest: a `def`→`defp` that would have compiled clean, passed all 3,569
> tests, and broken workspace seeding at runtime.
>
> **F9 → its own roadmap.** Dialyzer exits 2 with 56 findings on `main`, and the
> gate everyone believes is blocking has been red for a week. That is a bigger
> liability than anything deleted here.

> **Read §4b before trusting any list in here.** Four of this document's own
> findings were wrong, and the corrections are more useful than the findings:
> a `def`→`defp` that a green suite would have blessed and runtime would have
> broken, a file-scoped scan that cannot see module boundaries, a name-matching
> scan that cannot tell `foo` from `@foo` (eight items, plus two more it can
> never see), and a caution aimed at the wrong risk. **Every count below is a
> lower bound produced by grep, not an inventory.**

This is the third code-quality pass. The first two are closed and archived
(`07-17-26-code-quality-roadmap.md`, `08-03-26-code-quality-refactor.md`); their
survivors live in `LEFTOVERS.md`. **This document does not re-litigate either
one.** It measures what is here today and separates three things that look
identical from a distance: code with no caller, code with a caller that should
not be public, and code a linter was told to stop mentioning.

---

## 1. The numbers

Git-tracked source only. Build output is excluded — `desktop/tauri/target/`
alone holds 64,479 lines of generated Rust (four copies of a
`named_entities.rs` table), which would have made the Rust figure fifteen times
its real size.

| | Lines | Files |
|---|---:|---:|
| **Elixir — `lib/`** | 88,540 | 377 |
| **Elixir — `test/`** | 56,972 | 271 |
| Elixir — migrations | 1,762 | 53 |
| Elixir — config, `mix.exs`, seeds | ~3,567 | — |
| **Elixir total** | **150,841** | — |
| Rust (source) | 4,771 | 16 |
| JavaScript — source | 9,406 | 72 |
| JavaScript — tests | 1,494 | 15 |
| CSS | 1,196 | 1 |
| HEEx | 57 | 1 |
| Shell | 1,606 | 13 |
| TOML (Tauri ACL, cargo) | 455 | — |
| **Code total** | **~170,000** | 1,171 tracked |
| Markdown (`daily-growth/` is 48,136 of it) | 50,515 | 158 + |

**3,514 tests.** Test-to-source ratio in Elixir is 0.64:1, which is the number
worth remembering: this codebase is roughly two-thirds covered by weight, and
that is why most of what follows is small. A codebase this size with no test
gate would have yielded a much longer document.

Two ratios that are load-bearing later:

- **`lib/` is 88.5k lines across 377 files** — 235 lines average. The size gate
  (`scripts/check_file_sizes.sh`) currently reports `OK: file-size inventory
  holds`, so nothing is over its cap. The largest file is
  `commands/sound.ex` at 2,514 lines.
- **Documentation is a third of the Elixir codebase.** 48k lines of
  `daily-growth/` is not a defect — it is where every decision in this repo is
  recorded, and this pass depended on it. But it is now large enough that
  archiving on completion is load-bearing rather than tidy.

---

## 2. What is *not* wrong

Recorded so nobody spends an afternoon re-discovering it. Each of these was
checked and came back clean:

- **Zero orphaned modules.** All 378 modules defined in `lib/` are referenced
  from outside their own defining file. There is no abandoned subsystem.
- **Zero `TODO`, `FIXME`, `HACK`, or `XXX`** in `lib/`, `desktop/tauri/src/`, or
  `assets/js/`. The single grep hit is the string `+1XXXXXXXXXX` in a phone
  number format doc.
- **Zero skipped or pending tests.** No `@tag :skip` anywhere. The one excluded
  tag, `:browser_engine`, has its own CI workflow (`browser-engine.yml`) — it was
  given that lane in the 08-03 pass precisely because 22 tests were running
  nowhere.
- **Zero `#[allow(dead_code)]` or `#[allow(unused…)]` in Rust.** CI runs
  `cargo clippy --all-targets -- -D warnings`, so Rust dead code cannot land.
- **All 25 Mix dependencies are used.** The ten that look unused to a naive grep
  are tooling (`dialyxir`, `sobelow`, `mix_audit`), config-only
  (`ecto_sqlite3`, `phoenix_live_reload`), or referenced under a different
  module name (`telemetry_metrics` → `Telemetry.Metrics`).
- **The five Trading tables are properly dropped.** `portfolio_snapshots`,
  `portfolio_flows`, `realized_pnl_points`, `position_costs` and `symbol_bars`
  are all removed by `20260808070000_drop_trading_stack.exs`. My first pass
  reported them as orphans because it matched `drop table(:` and
  `drop_if_exists table(:` but not `drop_if_exists(table(:` — the form the
  migration actually uses. **The 08-08 deletion was clean.**
- **Test files are named by concern, not by module.** ~60 test files have no
  same-named module (`chat_surface_safety_test.exs`, `hooks_registered_test.exs`,
  `catalog_invariants_test.exs`). That is this repo's convention for
  cross-cutting tests and is not orphaning. Do not "fix" it.

---

## 3. Findings

### F1 — Twenty public functions with no caller anywhere

Verified: no occurrence of the name in `lib/`, `test/`, `assets/js/`, `priv/`,
`scripts/`, or `config/` outside the defining file, **including inside that file
itself**. These are not private helpers that lost their visibility; nothing calls
them at all.

They are not one thing, and the cleanup must not treat them as one. Three kinds:

**F1a — Scaffold residue (7). Delete.** `mix phx.gen`-shaped context CRUD that
was never wired to a caller:

| Function | File |
|---|---|
| `change_contact/2` | `contacts.ex` |
| `change_notification/2`, `update_notification/2` | `notifications.ex` |
| `delete_document/1` | `library.ex` |
| `list_shift_assignments/1` | `orchestration.ex` |
| `latest_shift/0` | `orchestration.ex` |
| `translate_errors/2` | `components/core_components.ex` |

`latest_shift/0` carries `@doc "The most recent shift regardless of status (e.g.
to read why it stopped)."` — a genuinely useful-sounding accessor that nothing
ever asked for. That is the shape to watch for: a docstring describes an
intention, not a caller.

**F1b — A self-declared legacy alias (1). Delete.**

```elixir
def builtin_shaders, do: @builtin_shaders

@doc "Built-in shader names (legacy alias of `builtin_shaders/0`)."
def home_shaders, do: @builtin_shaders
```

`appearance.ex:134`. The comment says what it is. Deleting it is the whole fix.

**F1c — Unwired feature surface (12: 4 resolved, 8 open). ASK BEFORE DELETING.**
This is the group that matters, and the reason this section is not a delete list.

**The music player was the first of these to be traced, and tracing overturned
the finding.** Recorded in full because the mistake is instructive:

*The original claim, which was wrong* — `music/player.ex` exposes a command API
where `request_previous/0`, `request_stop/0`, `request_volume/1` and
`clear_queue/1` have no caller while `request_toggle/0`, `request_next/0`,
`request_enqueue/1` and `request_seek/1` all do; therefore the dock UI never
grew a previous button, a stop button, or a volume control, and deleting these
would hide a missing feature.

*What is actually true* — **the dock has all three controls.** `music_player_live.ex`
wires them at lines 96–112 straight to the pure state functions
(`Player.previous/1`, `Player.stop/1`, `Player.set_volume/2`), because the dock
owns the player state locally and has no reason to go through PubSub to talk to
itself. The `request_*` wrappers are a *different path*: a remote control over
`command/1`, used by `music_component.ex` — the Music library tab — which offers
exactly four verbs (play this, queue this, pause, skip). Previous, stop and
volume are dock-local controls, so the library tab never needed to ask for them.

So these are **redundant wrappers on a remote-control API, not a missing
feature**. Nothing needs rewiring, and deleting them costs four lines and breaks
nothing. `apply_command/2` keeps every clause — including `:previous`, `:stop`
and `{:volume, _}` — because `music_player_live.ex:55` dispatches whatever
arrives on the topic through it, and `player_test.exs:335-355` asserts on `:stop`
and `{:volume, 20}` directly. **Deleted 08-09 on operator approval.**

The lesson generalises to the rest of F1c: *an uncalled wrapper in front of a
called function is not evidence of a missing feature.* Trace the callee before
believing the caller's absence means anything. The remaining F1c items below have
**not** been traced this way yet, so treat each as an open question rather than a
finding.

The same question applies to:

| Function | File | The question it is really asking |
|---|---|---|
| `sms_configured?/0` | `telephony/twilio.ex` | SMS is deliberately unwired (voice-first, no A2P). Is this ahead of its wiring, or left behind by it? |
| `unfloored_money_surfaces/0` | `model_policy.ex` | Reads like an audit helper for a test that was never written. `AGENT_BACKEND_ROADMAP` warns the model floor is unenforceable off Claude — this may be the measurement that argument needs. |
| `set_docked/2` | `agent/conversations.ex` | Docking conversations into sub-tabs. Shipped feature, or abandoned one? |
| `profile_complete?/0` | `setup.ex` | Onboarding gate with no gate behind it. |
| `by_status/0` | `finance/sources.ex` | `@doc` says "for the `finance_sources` listing" — so the listing does not use it. |
| `rel_path/0`, `pocket_name/0` | `introduction.ex`, `appearance.ex` | Trivial accessors; harmless either way. |
| `brand_pocket?/1` | `pockets/brand.ex` | **EXCLUDED — see §5.** Another session is editing this file today. |

### F1c rulings — operator, 08-09

All eight remaining items were traced before being asked about, and tracing moved
three of them out of "delete or wire" into something else entirely.

| Item | Ruling | What tracing found |
|---|---|---|
`sms_configured?/0` | **delete** | Duplicates the three conditions the live private `sms_ready/0` already checks for `send_sms/3`. A boolean copy of a tagged-error function. The boolean form is `sms_ready() == :ok` if a UI ever wants it. |
`profile_complete?/0` | **delete** | Its `@doc` claimed *"still used by the Settings page, so kept public."* **Zero callers.** Second false-caller docstring found this pass, after `resolve_source/1`. |
`rel_path/0` **+ `filename/0`** | **delete both** | `filename/0` was on no list — a sibling the scan could not see. Both attributes stay, used internally. |
`pocket_name/0` | **delete** | `@pocket` used 4× internally. |
`brand_pocket?/1` | **defer to the other session** | Dead, but `pockets/brand.ex` is under active edit today. Handed over rather than touched. |
`set_docked/2` | **delete the function *and* the column** | Not a dead function over live data — **`agent_conversations.docked` is a dead column.** This setter is its only writer and it is uncalled; nothing reads it; every row is `false` forever. Migration drops it, with a genuinely reversible `down/0` since no non-default value was ever written. |
`unfloored_money_surfaces/0` | **keep, and write the test it claims to have** | Its `@doc` promises *"the test guarding it fails"* — **no such test exists**, and `@floors` has been `%{}` since `trading_read`/`order_submit` left with the Trading stack, so it returns `[]` unconditionally. The new test asserts the invariant *and* asserts the vacuity state, so the guard is visibly dormant now and arms itself when a floor returns. |
`managed_kinds/0` | **derive from it, don't delete it** | See Pattern A. It becomes the single source of truth for a permission boundary that was stated three more times inline. |

Two of these are worth carrying forward as classes, not instances:

- **A docstring that names a caller is not evidence of one.** Three times now
  (`resolve_source/1`, `profile_complete?/0`, `unfloored_money_surfaces/0`) a
  function was public, or kept, on the strength of prose describing a caller or a
  test that did not exist. Prose is the least reliable index in this repo.
- **A dead writer can mean a dead column.** `set_docked/2` looked like one
  function; it was a schema field, a changeset entry, a migration and a setter.
  When the only writer of a field is unused, check the field, not just the
  function.

**The rule for F1c: each one is a one-line question to the operator, not a
deletion.** "Delete the unused function" and "wire up the missing button" are
opposite fixes, and only the operator knows which was intended — but as the music
player showed, sometimes neither is: the feature is already there by another
route. Trace first, then ask.

**A measurement caveat that affects this whole section.** The scan behind F1 and
F2 used fixed-string matching, so a function named `foo` and a module attribute
named `@foo` are indistinguishable to it. `default_volume/0` in `music/player.ex`
was reported as having two internal callers; both are `@default_volume`. Any
single-caller entry in F2 where the name doubles as a module attribute needs
re-verification, and the failure is self-announcing: convert such a function to
`defp` and `--warnings-as-errors` will call it unused, which means it was dead
rather than over-exposed.

### F2 — Sixty-one public functions used only inside their own module

`def` where `defp` was meant. Not dead — every one has a caller — but each is
API surface the module never intended to offer, which means it cannot be
refactored freely and shows up in any future dead-code sweep as noise.

Distribution:

| File | Count |
|---|---:|
`live/status/chat.ex` | 15
`orchestration.ex` | 6
`live/status/comms.ex` | 3
`library/artifact.ex` | 3
`integrations.ex` | 3
`cli.ex`, `notifications/cutup/signal.ex` | 2 each
27 other files | 1 each

**`status/chat.ex` is the interesting cluster, and it needs care.** That module
exists to be `import`ed by `status_live.ex` — the 08-02 purity extraction made
its functions public *on purpose* so template call sites stayed byte-identical
(this is recorded in memory as a standing pattern). So "public" there is
load-bearing for the module's real interface. The 15 listed are the ones
`status_live.ex` does **not** import: `push_msg`, `do_send`, `load_chat_history`,
`maybe_autotitle`, `to_chat_tab`, `scenes_for`, `render_scene`, `cap_list`,
`update_tab`, `mark_unread`, `maybe_speak`, `history_role`, `svg_ids_for`,
`title_from`, `announce_delivery`. Each was verified as having callers only
within `chat.ex` itself.

Two cautions for whoever does this:

1. **Function components cannot always be private.** `flash_group` (`layouts.ex`),
   `scene_card` (`chat_panel.ex`), `activity_row` (`comms.ex`), `cell_fill`
   (`calendar_colors.ex`) are HEEx components. A `<.foo />` call compiles to a
   local call and does work with `defp`, but a preceding `attr` declaration does
   not. Check for `attr` before converting, and leave the component public if it
   has one.
2. **This is exactly the sweep shape that has bitten this repo.** A visibility
   change across 34 files with a green suite the whole way is how the hook↔markup
   contract got severed once before. Do it in small file-scoped batches, and run
   the suite per batch, not once at the end.

### F3 — Nine unused CSS classes, 27% of the hand-written utilities

`app.css` defines 33 `ic-`/`bc-` classes. Nine appear nowhere in `lib/`,
`assets/js/`, or `test/`:

- `.ic-daygrid`, `.ic-daygrid-bar`, `.ic-daygrid-block`, `.ic-daygrid-head`,
  `.ic-daygrid-ruler`, `.ic-ruler-cell` — a calendar day-grid that the current
  `calendar_component.ex` does not use.
- `.ic-stat-l`, `.ic-stat-n` — stat label/number pair.
- `.ic-svg-card` — styles `svg` inside a card. Note this is Scene3D-adjacent;
  Scene3D shipped 08-08 and the memory records it as "validated JSON in, SVG card
  out", so confirm the shipped card does not depend on it before deleting.

**A tenth, found during the work and outside the inventory's reach:
`.chartbuild-svg svg`** — residue of the Chart Build stack deleted 08-08, sitting
at the same site in `app.css` with zero source references. The scan missed it
because it enumerated `ic-` and `bc-` prefixes only, which is a reminder that a
prefix convention is not a complete index of a stylesheet. Still present; not
deleted, because it was found after the lane's scope was fixed.

**Verify each against a running page, not just grep.** These are the one finding
class where a false positive is visible to the user, and CSS has no compiler.

### F4 — Seven over-broad JavaScript exports (one of them dead)

**Corrected 08-09 after the work was done. The original claim — "eight exports,
imported nowhere *and unused in their own file*" — was wrong twice over.**

The count was eight only by including `applyTermTheme`, which this section itself
then cleared; the real number is **seven**. And the second half of the claim was
never measured: the scan checked whether each name appeared in any file *other
than* the one defining it, which detects "not imported anywhere" and says nothing
about internal use. Asserting the stronger property was an overstatement, and it
would have licensed deleting six live functions.

What is actually true: **six of the seven are used inside their own file and are
merely over-exported** — the JS mirror of F2, not of F1. Only `DEFAULT_PALETTE`
had no reference at all. So six lost their `export` keyword and one const was
deleted.

The original (wrong) framing follows, kept for the record — `export`ed but
imported nowhere:

| Export | File |
|---|---|
`hexToVec4` | `audio/clipwave.js` |
`resolvePalette` | `hooks/smoke_background.js` |
`clawConfirm` | `lib/claw_confirm.js` |
`DEFAULT_PALETTE`, `hexToRgb` | `smoke/palettes.js` |
`DEFAULT_COLORS`, `clampR` | `smoke/params.js` |

`applyTermTheme` (`lib/theme.js`) was flagged and cleared — it has five callers
inside its own file. The `smoke/` cluster is residue from the Humo → homepage
collapse (07-04), which deleted the `/humo` tab and kept the shader as an
ambient background; these look like the parts the background does not need.
`clawConfirm` has a test (`claw_confirm_test.exs`) — check whether the test is
the only consumer before deleting either.

### F5 — One orphaned database table: `mcp_servers`

Created in `20260507150000_create_initial_rewrite_tables.exs` with a unique index
on `name` and indexes on `enabled` and `last_status`. **Never dropped, and
referenced by nothing** — no Ecto schema, no query, no code in `lib/` at all.

This is the residue of the MCP endpoint deletion in the pull-queue cut. The
scoped `:mcp` token tier survives in `api_token.ex` and is still live; the table
that backed the endpoint is not. Needs a `drop_if_exists` migration in the same
style as `drop_trading_stack.exs`.

### F6 — One stale Dialyzer suppression

`.dialyzer_ignore.exs` holds 86 entries. One names a file deleted on 08-08:

```elixir
{"lib/buster_claw_web/live/trading_live.ex", :unmatched_return},   # section 1
{"lib/buster_claw_web/live/trading_live.ex", :pattern_match_cov},  # section 2
```

Both should come out. The `pattern_match_cov` entry also carries a prose
justification —

> `sound_studio_component.ex`, `trading_live.ex` — LiveView catch-alls. A new
> error atom from an upstream contract (`TradingOrder.parse`, `StudioMix`)
> renders a generic message instead of crashing the whole page.

— half of which now describes a module that does not exist. The file's own stated
rule is *"entries come OUT as findings are fixed"*, and a deletion is the most
complete kind of fix.

**The remaining 84 entries are legitimate and should stay.** 75 are the
documented `:unmatched_return` baseline (deliberately not burned down, with the
reasoning written out); 9 are individually argued, and at least two —
`integrations/github.ex`'s fail-closed signature comparison and
`system_browser.ex`'s unknown-OS guard — must never be "fixed" to please a
linter. The file says so. Believe it.

*(This paragraph first said 85 and 76. Wrong: the heading counts this as one
finding, but it is **two entries** on the same file, so 86 − 2 = 84. Corrected
during the work.)*

### F7 — `mix precommit` is weaker than CI

Not dead code, but it is why some of this survived. The gates diverge:

| Gate | `mix precommit` | CI |
|---|:-:|:-:|
compile `--warnings-as-errors`, format, credo, `mix test` | ✅ | ✅ |
`check_cycles.sh`, `check_file_sizes.sh`, `check_rust.sh` | ✅ | ✅ |
**`bun test assets/js`** | ❌ | ✅ |
**`scripts/check_docs_drift.sh`** | ❌ | ✅ |
**`mix sobelow`, `mix deps.audit`** | ❌ | ✅ |
**Dialyzer** | ❌ | ✅ |

The sharp one: **1,494 lines of JS tests across 15 files never run locally.**
They do run in CI (`bun test assets/js`), so they are not dead — but a JS change
that breaks them passes a green `mix precommit` and fails after push. Given that
`theme.js`, `attachments.js` and the chat hooks all carry real logic now, this is
the gap most likely to cost an hour.

Sobelow and `deps.audit` live in the `lint` alias, so they are reachable; adding
`bun test` to `precommit` is a one-line change and the highest-value item in this
document relative to its size.

### F9 — The Dialyzer gate is red on `main`, and has been for a while

**Found while doing F6, and it is larger than anything else in this document.**
Verified independently: `mix dialyzer --format short` exits **2** with **56
findings** on a clean tree.

The cause is baseline rot. `.dialyzer_ignore.exs` was frozen on 08-02 with a
stated rule — *"A new `unmatched_return` in a file NOT listed here still fails the
build"* — and then never extended as new code landed. All 56 findings sit in 20
modules that **postdate the baseline**: `notes.ex`, `pockets/**`,
`agent/attachments.ex`, `terminal_theme.ex`, `chat_skin.ex`, `chat_text_size.ex`,
`clinch.ex`, `commands/sound.ex`, `live/status/{chat,chat_attachments,studio}.ex`,
`chrome_hook.ex`, `notes_component.ex`, `pockets_panel.ex`.

**44 of the 56 are `:unmatched_return`** — the exact class the baseline already
licenses for 75 other files, with the reasoning written out. That part is
bookkeeping, not defects.

**Twelve are the class that can be real defects**, and two clusters deserve a
proper look rather than an ignore entry:

- **`live/status/chat_attachments.ex:534–543`** — three `pattern_match_cov`, a
  `guard_fail` and a `pattern_match` inside one function. That combination says a
  clause list is unreachable past its first branch, which is a different thing
  from noise. Shipped with the attachments work.
- **`commands/sound.ex:796`** — `no_return: Function import_index/4 has no local
  return.` Dialyzer's claim is that this function can never return normally.
- `model_policy.ex:206` (`guard_fail`), `codex_app_server.ex:140` and `:153`
  (`pattern_match` — `{:error, _, _}` can never match), `commands/orchestration.ex:83`
  and `commands/sound.ex:1581` and `pockets_panel.ex:221` (`pattern_match_cov`).

**Seven of the 56 come from the 08-09 chat-skins and terminal-theme work**
(`terminal_theme.ex` ×5, `chat_skin.ex`, `chat_text_size.ex`). All seven are
`:unmatched_return` on `Settings.put`/`PubSub.broadcast` calls — so that work
added baseline-class noise and no defects, but it added it without extending the
baseline, which is precisely how the gate got here.

**Why this outranks F7.** This repo pushes straight to `main` with no PRs, so CI
runs *after* the fact and blocks nothing. A red gate nobody is blocked by is
indistinguishable from no gate — and it is worse than none, because the 08-02
document says it gates, and memory says it gates, so everyone believes a check is
running that is not. That is the same failure the file-size gate was built to
prevent for module size: *the lesson is a rate, not a job.*

**Not this roadmap's work.** Deciding, for each of the twelve, whether it is a
defect to fix or noise to baseline is a different exercise from deleting dead
code, and several of the files are on the never-touch list in §5. It wants its own
item. What belongs here is the measurement, so the next person starts from 56 and
a date rather than from "Dialyzer gates CI".

### F8 — Housekeeping

- **15 stale digested CSS bundles** (plus `.gz`) in `priv/static/assets/css/`,
  from repeated `phx.digest` runs. Gitignored, so local-only cruft.

  **DO NOT clear them with `mix phx.digest.clean --all`.** Running it on 08-09
  deleted **14 tracked font files** — `priv/static/fonts/archivo-600-<hash>.woff2`
  and friends. `.gitignore` excludes `/priv/static/assets/` but **not**
  `/priv/static/fonts/`, where the digested `-<hash>.woff2` variants are
  deliberately committed alongside their plain names. `digest.clean --all` does
  not respect `.gitignore`; it cleans every digested artifact under
  `priv/static`, committed or not. Recovered with `git checkout -- priv/static/fonts/`
  before anything was staged, so the cost was nil — but the safe form is to
  delete inside `priv/static/assets/` directly, or accept the cruft, which is
  invisible anyway. This is the one item in this document whose "fix" was more
  dangerous than the finding.
- **Two completed roadmaps still in `roadmaps/`.** `CHAT_SKINS_ROADMAP.md` and
  `TERMINAL_THEME_ROADMAP.md` both read *"SHIPPED 08-09. Only the operator walk
  remains."* Repo convention archives on completion; `archive/` holds 100 files.
  Both should move once their G-40 walks are signed off — **not before**, since
  the walk is the last open phase.

---

## 4. Dispatch plan

Four lanes, **disjoint file scopes**, each with its own test partition. This
follows the standing rule that parallel agents need a contract before fan-out: no
two lanes touch the same file, and the boundary is the file list below rather
than a description.

| Lane | Scope | Findings | Risk |
|---|---|---|---|
**A — Delete the certain** | `contacts.ex`, `notifications.ex`, `library.ex`, `orchestration.ex`, `appearance.ex`, `core_components.ex` | F1a + F1b (8 functions) | Low. Compiler and suite prove it. |
**B — Visibility** | the F2 files **minus** lane A's six, minus `layouts.ex` and `chat_panel.ex` | F2 (52 of 61) | Medium. Small batches; check `attr` before converting components. |
**C — Assets** | `assets/css/app.css`, `assets/js/**` | F3 + F4 | Medium. **CSS needs a visual check**, not just a green suite. |
**D — Schema, suppressions, gates** | new migration, `.dialyzer_ignore.exs`, `mix.exs` | F5 + F6 + F7 | Low, and independently valuable. |

**The lanes overlapped on first draft and the split above is the correction.**
F2's list includes `library.ex` (`update_document`) and `orchestration.ex` (six
functions) — both already inside lane A's delete scope. Two agents editing one
file concurrently is a merge conflict in a shared working tree, so those **seven
conversions are held and done by hand after lane A lands**. Worth recording
because it is the predictable failure of scoping lanes by *finding* rather than
by *file*: the findings are disjoint, the files are not. Scope by file.

Held for a second pass, after lane A:

| Function | File |
|---|---|
`update_document/2` | `library.ex` |
`complete_shift/1`, `kill_switch_path/0`, `shift_assignment_role/1`, `shift_assignment_roles/0`, `shift_job/1`, `shift_jobs/0` | `orchestration.ex` |

Also held: `flash_group/1` (`layouts.ex`) and `scene_card/1` (`chat_panel.ex`) —
see §5.

**Every lane that runs the suite gets its own `MIX_TEST_PARTITION`** (`laneA`
… `laneD`). Another session runs `mix test` against the same SQLite file, and an
unpartitioned run produces "database busy" and dozens of phantom failures.

**F1c is not a lane.** Those twelve functions go to the operator as questions
before anyone touches them.

---

## 4b. What actually landed, 08-09

All four lanes ran. Every gate green afterwards: compile `--warnings-as-errors`,
`format --check-formatted`, `credo --strict`, **3,505 Elixir tests + 195 JS tests,
0 failures**, cycles, file sizes, docs drift, Rust.

| | Result |
|---|---|
**F1a + F1b** | 8 functions deleted, −37 lines, zero false positives |
**F1c** | 8 traced then ruled on: **6 deleted** (incl. a database column), 1 kept behind a new test, 1 promoted to a source of truth, 1 handed to the other session |
**F2** | 42 → `defp`, 5 deleted, 9 escalated to Phase 2 |
**F3** | 10 CSS rules gone (9 + `.chartbuild-svg`), −160 lines |
**F4** | 1 const deleted, 6 exports narrowed |
**F5** | `mcp_servers` dropped, rollback exercised both ways |
**F6** | 2 stale entries + their prose removed |
**F7** | `bun test assets/js` now in `precommit` |
**F8** | digest cruft **left alone** — the recommended fix turned out to delete tracked fonts (see F8); the 2 roadmap archives correctly still wait on their G-40 walks |
**F9** | measured only — 56 findings, its own roadmap |
| Held 7 (lane overlap) | 5 → `defp`, **2 were dead**, 1 unreachable clause collapsed |
| **Phase 2 (§4c)** | Pattern A derived, B tested, C guarded, D deleted — all four closed |

Four things were **added**, not removed, and they are the durable half of this
pass:

| New | Guards |
|---|---|
`test/buster_claw/workspace_seed_lockstep_test.exs` | 11 `{module, fun}` seed contracts, invisible to grep and to the compiler |
`dispatch_projector_test.exs` — byte-identity test | The append-only diary equals `render_diary/2`; it **passed**, so the optimisation is sound |
`model_policy_test.exs` — 2 floor tests | The invariant *and* its own vacuity state, looping over `backends/0` |
`clinch_test.exs` — `managed?` agreement | Every listing entry against `Types.managed_kinds/0`, non-vacuously |

Bonus deletions the original scan structurally could not see, found only by
working the findings: `statuses/0`, `categories/0`, `CalendarColors.text/1`,
`Introduction.filename/0`, `.chartbuild-svg`. Plus one **kept**:
`messaging_service_sid/0` looked dead and had three live internal callers — it
became private instead.

### The four things the estimate got wrong

**1. `write_readme/0` was a runtime trap, and only a human sweep found it.**
It is registered dynamically as `seed: {__MODULE__, :write_readme}` in the same
file. Converting it to `defp` **compiles clean, passes all 3,505 tests, and
breaks workspace seeding at runtime.** A `{__MODULE__, :fun}` registry entry is
invisible to a grep for `fun(` *and* to `--warnings-as-errors`. This was the one
item on a 52-line list where a green suite proved nothing — worth remembering
next time a sweep is justified by "the suite is green the whole way".

**2. Same file ≠ same module.** `twiddles/1` lives in a nested
`Signal.Tables` module and is called from its sibling `Signal` module in the same
file, so a file-scoped scan called it internal-only. The compiler caught it
loudly. `bit_width/1` in the same file was genuinely internal and converted —
so the file was half right, which is the worst case for a heuristic.

**3. The `@foo`/`foo` false positive was eight items, not one.** Beyond
`default_volume/0`, seven more F2 entries had **no caller at all** — every
credited "internal call site" was a module-attribute reference: `cell_fill/1`,
`managed_kinds/0`, `series_catalog/0`, `render_diary/2`, `service_types/0`,
`severities/0`, `id_required/0`. They are F1-class, not F2, and were **left alone
rather than deleted** because only the music player was operator-approved and
several are F1c-shaped. Two of their siblings — `statuses/0`
(`integrations/integration.ex`) and `categories/0` (`sentinel/event.ex`) — are
equally dead and appear on **no list in this document**, because a scan that
matches a name against an attribute of the same name cannot see them either.

**4. The `attr`/`slot` caution was a non-issue.** Exactly one of the 34 files
declares `attr` at all, and it belongs to a different component. None of the 52
were HEEx components: `activity_row/2` builds a map, `trim_cost_zeros/1` is string
arithmetic, `cell_fill/1` returns a class string. The caution cost nothing, but it
was aimed at the wrong risk — the real one was dynamic dispatch.

Also recorded: `resolve_source/1` carried `@doc "Public for StatusLive, which
selects the mix a render came from."` — **a claim that was never true**
(`git log -S resolve_source -- status_live.ex` is empty). It was not preserved
verbatim on the way to a comment. A docstring asserting a caller is not evidence
of one.

### Two lessons about running agents in a shared dirty tree

**1. A subagent cannot tell your earlier work from another session's.** Twice,
agents launched into this tree reported changes as "another session's, already in
the file when I read it" that were in fact **this effort's own earlier lanes** —
`home_shaders/0`'s deletion and `.ic-svg-card`'s removal (lanes A and C), and
`floor_applies?/2`'s `def`→`defp` (lane B). Both reports were careful and
well-intentioned, and both were wrong in the same direction: an agent sees only
`git status`, which does not say *who*. The cost was zero here because nobody
staged on that basis, but the fix is cheap and worth doing next time — **tell each
agent which files the earlier lanes already touched**, or it will invent a
plausible attribution.

**2. A brief can under-specify a guard and an agent can catch it.** The floor test
was briefed as "assert the invariant, and assert the vacuity state". The agent
found a *second* vacuity the brief missed: with no policy stored, `backend_for/1`
returns `nil` and `bucket(nil)` is `:claude`, so `floor_applies?/2` is true and
every surface is filtered out **even with a floor declared**. A test asserting
`unfloored_money_surfaces() == []` would therefore have stayed green after a floor
was added, which is exactly the failure it was written to prevent. The fix was to
loop over `ModelPolicy.backends()`, lowering the stored *global* default to each
harness in turn — which also means a fourth backend is covered without an edit.
It proved the failure mode in a scratch replica: `:codex` and `:opencode` yield
`[:order_submit]`, `nil` and `:claude` yield `[]`. **The vacuity you can see is
rarely the only one.**

---

## 4c. Phase 2 — the refactor for the nine held functions

**Scoped 08-09, not started.** Lane B left nine functions public rather than
guess. Read individually they are nine judgment calls; read together they are
**four patterns, and the pattern decides the fix**. Only one of the four is
"delete it".

Deleting all nine would have been the fastest wrong answer: three of them are
evidence of something missing, and the fix that removes the evidence is worse
than the one that acts on it.

### Pattern A — one list, two sources of truth → *derive, don't delete*

**`Clinch.Types.managed_kinds/0`** returns `[:sign_in]` and documents itself as
*"the kinds `Clinch` can write today. Everything else is listed read-only."*
Nothing calls it. Meanwhile `clinch.ex` hardcodes the same fact three times:

```elixir
lib/buster_claw/clinch.ex:176   |> Enum.map(&Map.merge(&1, %{kind: :sign_in,     managed?: true}))
lib/buster_claw/clinch.ex:184   |> Enum.map(&Map.merge(&1, %{kind: :oauth,       managed?: false, …}))
lib/buster_claw/clinch.ex:193   |> Enum.map(&Map.merge(&1, %{kind: :service_key, managed?: false}))
```

So "which credential kinds are writable" is stated in two places that agree today
and are kept in step by nothing — **the exact shape the terminal-theme roadmap
found and fixed for palettes**, and the shape this repo keeps getting bitten by.

It also happens to be **security-adjacent**: the Clinch roadmap's central decision
is that remote may *use* credentials but never *manage* them, and `managed?` is
what the UI reads to decide whether to offer an edit
(`clinch_panels.ex:102` renders "· read-only" from it). Two copies of a
permission boundary is one copy too many.

**Fix:** `clinch.ex` derives it — `managed?: kind in Types.managed_kinds()` — and
a test asserts the three list entries agree with `managed_kinds/0`. The dead
function becomes the single source of truth, and Phase 3 of the Clinch roadmap
(next up) inherits one list instead of four.

### Pattern B — a pure reference implementation with no test → *write the test*

**`DispatchProjector.render_diary/2`.** The moduledoc explains exactly why it
exists: the dated diary is written **append-only**, one row per event, so a busy
day costs O(1) per event rather than O(n²) — and `render_diary/2` is the pure
re-render that *should* reproduce the same bytes. Its own docstring claims
*"byte-identical to the append-only file for the same event sequence."*

**Nothing asserts that claim.** `dispatch_projector_test.exs` has 7 tests; the
closest (line 146, *"the diary md is appended per event under a single header"*)
checks the append path against itself, never against the re-render. So the
function whose entire purpose is to be the oracle for an optimisation is the one
thing not wired to a test.

**Fix:** one property-shaped test — append N events through the real projector,
then assert the file on disk equals `render_diary(date, events)`. That converts a
dead function into the assertion that makes the append-only optimisation safe to
keep. Cheapest high-value item in this section.

### Pattern C — an invisible contract → *add a lockstep guard*

**`write_readme/0`** is correctly public: `workspace.ex:60` registers it as
`seed: {__MODULE__, :write_readme}`. It is not alone — **the registry holds eight
`{module, fun}` seeds**, pointing at `Introduction.ensure`, `WorkspaceCLI.ensure`,
`Library.Artifact.ensure_workspace_dirs`, `Jobs.ensure`, `Skills.ensure`,
`Pages.ensure`, `Journal.ensure`, `Notes.ensure`, `Notifications.Sound.ensure`
and `Shaders.ensure`. Every one is invisible to a grep for `fun(` **and** to
`--warnings-as-errors`, and `run_seed/1` calls them by `apply/3`.

This is the finding Lane B nearly shipped a runtime break on, and the fix is not
"remember harder".

**Fix:** a test that reads the registry and asserts every `seed:` MFA is
exported by its module. Eight contracts asserted at once, and the same test
catches a renamed seed, a deleted one, and a typo. **This repo already has the
pattern** — the Tauri ACL lockstep guard and `hooks_registered_test.exs` are the
same idea; this extends it to the one registry that still has no guard.

**`twiddles/1`** needs no code change: it is public because it lives in the nested
`Signal.Tables` module and is called from its sibling `Signal`. It costs one
comment saying so, which is what stops the next sweep from converting it again.

### Pattern D — an accessor for a UI that never arrived → *delete*

Nine deletions. In each case **the underlying module attribute stays and stays
used**, so nothing loses a source of truth — only the never-called reader goes:

| Delete | File | The attribute survives because |
|---|---|---|
`service_types/0`, `statuses/0` | `integrations/integration.ex` | `validate_inclusion` uses both (`:67`, `:68`) |
`severities/0`, `categories/0` | `sentinel/event.ex` | `validate_inclusion` uses both (`:40`, `:41`) |
`id_required/0` | `commands/catalog/helpers.ex` | `@id_required` is used directly by `get_entry/2` |
`series_catalog/0` | `finance/bls.ex` | `@known_series` is read at `:142` to describe a series |
`cell_fill/1`, `text/1` | `buster_claw_web/calendar_colors.ex` | — (see below) |
`by_status/0` | `finance/sources.ex` | — (see below) |

Two of these carry a second defect that must be fixed in the same commit:

**`CalendarColors` — a false moduledoc, and a tenth dead function this document
never listed.** The module claims to serve *"the two calendar surfaces — the home
corner-widget month grid (`HomeWidget`) and the full calendar page"*. **`HomeWidget`
does not reference `CalendarColors` at all.** Of five treatments, three are live
(`cell_wash` ×1, `chip` ×2, `swatch` ×1) and **two are dead — `cell_fill/1` and
`text/1`.** `text/1` appears nowhere in this document because the scan matched
fixed strings and `text` occurs in nearly every file: the same blind spot that hid
`statuses/0` and `categories/0`. The module was built for two surfaces and only
one arrived; the fix is to delete the two unused treatments and correct the
moduledoc to name the one real consumer. Not to build a home calendar widget on
the strength of a docstring.

**`Sources.by_status/0` is not a deduplication opportunity, despite appearances.**
Its `@doc` says *"Group by status, for the `finance_sources` listing"*, and
`commands/finance.ex` does have a `filter_status/2` — but the shapes differ:
`by_status/0` groups into a map of every status, `filter_status/2` filters to one
requested status. Swapping one for the other would change the command's output.
Delete the accessor; leave the command alone.

### Sequencing

| | Work | Risk |
|---|---|---|
1 | **Pattern C guard** — the seed lockstep test | None. Pure addition, and it protects the rest. |
2 | **Pattern D** — 9 deletions + the moduledoc fix | Low. Attributes stay; compiler and suite prove it. |
3 | **Pattern B** — the diary byte-identity test | Low, and it may *fail*, which would be the point. |
4 | **Pattern A** — Clinch derives `managed?` | Lowest volume, highest care. Touches a permission boundary; do it alone, not batched. |

Do 1 first: it is the only item that makes the others safer. Do 4 last and by
hand — `clinch/**` is the active roadmap's territory and Phase 3 is next, so it
wants a human deciding whether `managed_kinds/0` is still the right shape before
three call sites start depending on it.

---

## 5. Exclusions — files another session is editing today

A second session is actively working on Pockets and brand art. Its last three
commits touched:

```
lib/buster_claw/pockets/brand.ex
lib/buster_claw_web/chrome_hook.ex
lib/buster_claw_web/components/brand_art.ex
lib/buster_claw_web/components/layouts.ex
lib/buster_claw_web/live/dock_nav_live.ex
lib/buster_claw_web/live/require_onboarding.ex
lib/buster_claw_web/live/status_live.ex
test/buster_claw_web/live/brand_upload_test.exs
```

`POCKETS_ROADMAP.md` was modified at 08:51 today, so this is live.

**Two of this document's findings sit inside that set and are therefore held:**

- `brand_pocket?/1` in `pockets/brand.ex` (F1c) — may be about to get its caller.
- `flash_group/1` in `layouts.ex` (F2) — a component in a file being edited.

No cleanup agent may write to any path in that list. Standing rule for this
working tree: **never `git add -A`** — stage explicit paths, because a shared
tree has already cost one polluted commit.

---

## 5b. Left open, with triggers

**The `docked` feature's third limb, in JavaScript.** Docking was built in three
places and wired to none: the `agent_conversations.docked` column, the
`set_docked/2` setter (both deleted 08-09), and
`assets/js/hooks/chat_window.js:82-89`:

```js
docked() { return this.el.dataset.docked === "true" },
…
applyStoredGeometry() {
  // A docked chat is sized by the tab it fills. Writing left/top/width onto it
  // would drag it back out of the flow and pin it over its own panel.
  if (this.docked()) return
```

**This is not dead code and was deliberately not deleted under the same ruling.**
`docked()` has a real caller, and it returns a valid answer — but **no template
anywhere renders `data-docked`** (zero hits across `lib/`, `assets/`, `test/`), so
the guard never fires. It is an *inert branch*, a different category from a
column nothing writes, and the operator's ruling on the column does not
automatically reach it.

The trigger, both ways: **if docking is ever built, this is where it starts** and
the guard becomes live the moment a template emits `data-docked`. **If docking is
abandoned, these eight lines go** — and the comment explaining why a docked chat
must not be positioned goes with them. Do not delete it as "unused JS" without
making that call, because the comment is the only surviving description of what
docking was supposed to do.

---

## 6. What this pass deliberately did not do

- **No module-size refactoring.** The size gate holds and the largest files were
  argued in the 08-03 pass. Re-opening it here would be a second roadmap wearing
  this one's name.
- **No burn-down of the 76 `:unmatched_return` entries.** The file argues that
  rewriting 232 call sites across 76 files is a wide no-behaviour-change sweep
  with a green suite the whole way — the exact shape that has bitten this repo.
  That argument still holds.
- **No duplicate-code detection.** Fuzzy, and it produces findings nobody acts
  on.
- **No documentation pruning.** 48k lines of `daily-growth/` is the reason this
  review could tell an orphan from a decision. The only doc item here is
  archiving two finished roadmaps.
