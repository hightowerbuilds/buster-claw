# Code Quality — Refactoring Roadmap

**Reviewed:** 2026-08-02 · **Status:** IN PROGRESS · **Scope:** Maintainability, modularity, dependency direction, dead code, suppressed findings, and testability.

> ## Re-measured 08-03 — this roadmap is NOT done
>
> Checked against the tree rather than the checkboxes, because two other
> roadmaps this week asserted things that were not true. **The 08-02 work all
> holds. What it did not do is stay done, and the remaining phases were never
> started.**
>
> **A result silently regressed.** Cycles went 6 → 2 on 08-02 with the note
> *"no `lib/buster_claw` file participates in any cross-layer cycle now."* On
> 08-03 there were **3**: `Trading → ChartBuilder → Portfolio → Trading`, closed
> by one line (`chat_opts_for("chartbuild")`) added with the Chart Build tab
> that morning. Fixed the same day by extracting
> `BusterClaw.Trading.ChatProfile` as a leaf — the same technique
> `AgentToolPolicy` and `AudioName` used.
>
> **Nothing was watching, so nothing complained.** `scripts/check_cycles.sh` now
> asserts the *inventory* — the two accepted cycles by name and reason, anything
> else fails — and runs in `mix precommit`. Probed by reintroducing the real
> cycle and confirming it fails, not by trusting it. **A number nobody checks is
> a number that drifts back**, which is the reusable lesson from this roadmap's
> own README-guard story.
>
> **`TradingLive` grew back.** 3,503 → 1,900 was real (−46%), and it is
> **2,174** today: Chart Build and the rest landed on top of it. This is not a
> failed refactor — the extraction held, the file simply kept accreting — but it
> means Phase 3A's win is a rate, not a destination, and the item is now carried
> in `LEFTOVERS.md`.
>
> **Measured 08-03, all still open:**
>
> | Target | 08-02 claim | 08-03 actual |
> |---|---|---|
> | `SoundStudioComponent` (3B) | 1,933 | **1,933** — untouched |
> | `StatusLive` (3B) | 1,400 | **1,420** — untouched |
> | `TradingLive` (3A, done) | 1,900 | **2,174** — regrew |
> | `PortfolioChart` (3C) | — | 996 |
> | `Commands.Web` (3C) | — | 894 |
> | `CLI` (3C) | — | 867 |
> | `TerminalCommands` (3C) | — | 795 |
> | `Gmail` (3C) | — | 739 |
>
> ### Scope decided 08-03 — what is actually left
>
> The remaining work was read for whether we would defend it, not just listed.
>
> **Doing:** the **payload-key lockstep** (the bridge test compares action
> *names*, so renaming `"wait_ms"` on one side is still silent), a scheduled
> **`:browser_engine` lane** (those 22 tests appear nowhere in
> `.github/workflows/` — coverage written and never collected), and **3B**
> (`SoundStudioComponent` 1,933 and `StatusLive` 1,420 genuinely do several jobs
> each).
>
> **Cut, with reasons recorded in place:** **3C** — dropped by this document's
> own argument, since its scorecard already says Finding 4 used the wrong axis
> and 3C listed five coherent mid-sized modules on it. The **daisyUI
> contradiction** — resolved by correcting `AGENTS.md`, which was describing
> neither the code nor a destination. **Source archaeology** was already cut.
>
> **Still open, unranked:** Phase 4's remaining items (nested-module extraction,
> inline theme JS, browser-page consolidation), Phase 0 item 8 (voice
> edge-function tests), and **UML sections 3–5** — docs that have certainly
> drifted, since sections 1–2 had; worth fixing only if someone reads them, and
> worth marking dated if not.
>
> **The lesson 3B has to carry.** `TradingLive` was cut 46% and regrew to 2,174
> within a week. Splitting a module buys a rate, not a destination, unless
> something makes the regrowth visible — the way `scripts/check_cycles.sh` now
> does for cycles.
>
> Do not archive this document on the strength of its Progress section: that
> section is accurate about 08-02 and says nothing about the phases that were
> never begun.

> **Verification pass, 2026-08-02 (second reader).** Every structural number in
> this document was re-measured and holds exactly: the module line counts, the
> five xref cycles, the 105-file compile component, the 253 Dialyzer findings,
> the `--format short` crash. The *findings built on top of them* did not all
> hold. Findings 1, 2, and 4 are corrected in place below — read the **CORRECTION**
> blocks, not the original prose above them. Two items prescribed work that was
> already done; one would have opened a security hole if implemented literally.
> Findings 3 and 5 have not been re-examined.

> **Verdict:** The codebase is healthy in breadth but uneven in concentration.
> Formatting, compilation, Credo, and the multi-language test suites are strong;
> the main quality debt lives in a small number of oversized modules, five
> dependency cycles, duplicated cross-language contracts, stale behavioral
> documentation, and a Dialyzer job that currently cannot protect the build.

This is a refactoring plan, not a feature roadmap. It preserves behavior first,
then improves the boundaries underneath it. Applied migration history is not to
be rewritten, and large modules are not to be split merely to make line counts
smaller.

---

## Baseline recorded during the review

The review covered the Phoenix/Elixir application, LiveViews and components,
JavaScript hooks and browser chrome, the Rust/Tauri shell, Supabase edge
functions, migrations, tests, scripts, CI, and product/architecture documents.

### Passing checks

- `mix format --check-formatted`
- warnings-as-errors compilation
- `mix credo --strict`
- command/documentation drift check
- 2,143 Elixir tests, 0 failures, 22 real-browser tests excluded by tag
- 120 JavaScript tests, 0 failures
- 34 Rust tests, 0 failures
- 2 Deno SMS tests, 0 failures

### Structural findings

- 281 tracked Elixir source files
- 5 dependency cycles
- 1 compile-connected cycle spanning 105 files
- 253 Dialyzer findings with the default formatter
- the CI `--format short` Dialyzer invocation crashes on the pinned toolchain's
  `:exact_compare` warning, and the job is non-blocking

### Largest concentration points

| Module | Lines | Approx. functions | Responsibilities mixed together |
|---|---:|---:|---|
| `BusterClawWeb.TradingLive` | 3,503 | 290 | Chat, tabs/windows, research, orders, accounts, portfolio, charts, async work, rendering |
| `BusterClawWeb.SoundStudioComponent` | 1,933 | 141 | Catalog, file operations, editing, arrangement state, analysis, rendering |
| `BusterClawWeb.StatusLive` | 1,400 | 122 | Chat, Studio history, contacts, notifications, weather, music, SVG viewing |
| `BusterClawWeb.PhoneLive` | 1,275 | 75 | Activity, contacts, trust, PINs, dialpad, stats, presentation |
| `BusterClaw.Trading` | 1,270 | 94 | Prompts, agent policy, caching, fetch orchestration, parsers, view shaping |
| `BusterClaw.Portfolio` | 1,023 | 66 | Snapshots, exclusions, transfers, gains, anomalies, backfills, cost basis |
| `BusterClawWeb.PortfolioChart` | 1,047 | 73 | Series preparation, geometry, SVG rendering, symbol chart, sparkline |
| `BusterClaw.TerminalCommands` | 928 | 87 | Defaults, persistence, migration, editing, validation, rendering data |
| `BusterClaw.CLI` | 822 | 137 | Parsing, aliases, transport, rendering, signals, errors |
| `BusterClaw.Commands.Web` | 794 | 75 | Fetch, live-browser actions, flows, checks, bookmarks, history, downloads |

---

# Part I — Findings that change the order of work

## 1. Behavioral documentation is not a trustworthy contract

> ### CORRECTION (08-02) — demoted to P2. **Do not implement the headline as written.**
>
> **The two statements belong to two different agents, and each is true of its
> own surface.** There are two Robinhood-facing prompts:
>
> 1. `INTRODUCTION.md` (generated by `introduction.ex`) is the workspace guide
>    for the operator's **own terminal `claude` session**.
> 2. The Trading chat gets `Trading.@system_prompt` (`lib/buster_claw/trading.ex:125-176`)
>    via `append_system_prompt` in `chat_opts/0` (`trading.ex:280`). The Trading
>    chat never reads `INTRODUCTION.md`.
>
> Prompt 2 is **already completely current**: it says the chat has no order tool
> and never will, that it may only PROPOSE, that the operator's click — not the
> message — reaches the broker, and it specifies the ```` ```order ```` fence,
> the six required fields, and the `agentic_allowed` precondition. Nothing about
> it is stale. The original reviewer never found this file.
>
> **Implementing the proposed fix would be a security regression.** The terminal
> agent runs in the operator's own CLI where `mcp__robinhood__*` may be live from
> a one-time `claude mcp login robinhood`. `Trading.read_only_cli_args/0` applies
> only to app-spawned runs — outside `trading.ex` and `research.ex` nothing passes
> `--disallowedTools`. For that session, *"You may not place, amend, or cancel an
> order"* is prompt-only policy **because it has to be**. Rewriting it to "you may
> propose behind confirmation" grants a permission that session can actually
> exercise, with no confirm card in front of it — the fence parser lives in
> `trading_live.ex:622` and never sees a terminal turn.
>
> **What is actually wrong** is two sentences at `introduction.ex:607-608`:
> "explain that execution is disabled, and stop." Execution is not disabled, it
> moved. Keep the prohibition verbatim; fix only the referral —
>
> > If asked to trade, research and draft the proposed order, then say plainly
> > that you cannot place it from here — the Trading tab can. Describing the
> > trade there returns a confirmation card the operator clicks. Never imply
> > that a draft was submitted.
>
> Five minutes, no change to the guardrail. **Not a blocker for anything.**

The generated operating guide tells the agent that it may not place orders and
must say execution is disabled. The application now supports a structured order
proposal followed by a separately confirmed submission through `TradingOrder`.
Those two truths cannot coexist.

Other drift found during the review:

- README and architecture docs still refer to `shift/Dispatch.md`; the current
  projection is top-level `Dispatch.md`.
- README tells the user to read a plaintext API-token file, while the packaged
  shell migrates tokens into the macOS Keychain and injects them into the app and
  terminal environment.
- UML diagrams no longer describe the current supervision tree and domains.
- The voice edge-function comment says the Mac subscribes through Realtime,
  while the implemented design polls PostgREST and calls the Realtime
  publication vestigial.
- Desktop packaging still lists bundled Playwright dependencies as deferred even
  though that sidecar was deleted.

This is not cosmetic. `INTRODUCTION.md` is part of the model's runtime policy.
Semantic drift there can change behavior even while every unit test passes.

**Priority:** ~~P0~~ → **P2 overall**, with one item pulled out as P1.

> **CORRECTION (08-02) — the sub-items, re-verified and re-ranked:**
>
> | Item | Verified | Real severity |
> |---|---|---|
> | README token file vs Keychain | Real — `README.md:76,109` tell the user to `cat …/api_token`; `docs/DESKTOP_PACKAGING.md:34` says the packaged shell migrates plaintext files **into** the Keychain | **P1** — the only one that strands a user mid-task |
> | `shift/Dispatch.md` | Real in `README.md:17`, `docs/ARCHITECTURE.md:26`, `docs/UML.md:283`, `user-guide/daily-loop.md:14,34` — but `test/buster_claw/introduction_test.exs:71` **already guards the generated guide** | P2, prose only |
> | Voice transport comment | Real — `supabase/functions/voice/index.ts:9-10` claims a Realtime subscription; the Mac polls PostgREST | P2, comment only |
> | Playwright in packaging docs | Real — `docs/DESKTOP_PACKAGING.md` still lists it | P2, prose only |
> | UML supervision tree | Not re-verified | P2 |
>
> Do the README credential path. The rest is a documentation chore that gates
> nothing.

## 2. Dialyzer is suppressed at the build level

CI marks Dialyzer `continue-on-error: true`. With the pinned Elixir/OTP stack,
the configured short formatter crashes before it can render an
`:exact_compare` finding. Running with the default formatter produces 253
findings.

Most findings are `:unmatched_return` reports from deliberately ignored
best-effort calls. The same output also identifies real dead branches and
over-covered patterns in browser, finance, Studio, appearance, CLI, and trading
code. Until the signal is separated from the noise and the job gates merges,
static analysis is decorative.

**Priority:** P0 — confirmed, but **far smaller than this section implies.**

> ### CORRECTION (08-02) — the triage, actually run
>
> ```
> 232  unmatched_return
>   9  pattern_match_cov
>   5  pattern_match
>   3  unknown_type
>   2  no_return
>   1  call
> ```
>
> **92% is one warning class**, spread thin (worst file has 13) — a global style
> artifact, not a hotspot. The real-signal bucket is **~20 findings, not 253.**
> This is a day of reading, not an epic.
>
> **Phase 0 item 4 is half-impossible as written.** `mix hex.info dialyxir` says
> **1.4.7 is the latest release** — there is no upgrade. And `--format github`
> crashes identically to `--format short` (same `Formatter.Utils.warning/1`
> throw on `:exact_compare`). The **default `dialyxir` formatter is the only one
> that survives.** That item collapses to deleting `--format short` from
> `.github/workflows/ci.yml:162`.
>
> #### It was hiding a live bug — `cli.ex:214`
>
> `System.trap_signal(:sigint, …)`. OTP reserves SIGINT for the BREAK handler; it
> cannot be trapped. Confirmed directly: `no function clause matching in
> System.trap_signal/3`. The call raises immediately and the `rescue _ -> :ok`
> below it swallows the error. Meanwhile `cli.ex:161` promises:
>
> > Closing is one keystroke: Ctrl-C stops polling **and** stops the shift.
>
> It never has. Ctrl-C during `on-duty` kills the CLI while **the shift stays
> open server-side** — the autonomous mail loop keeps running after the operator
> believes they stood it down. Only an explicit `off-duty` stops it. 2,143 tests
> were green over this. **Fix separately from the gating work.**
>
> Three more real ones:
>
> - **`cli.ex:608`** — the `{:failed_connect, _}` clause is dead httpc-era shape.
>   Under Req, connection-refused falls through to the generic `"request failed:
>   …"`, so the helpful *"is `mix phx.server` running?"* line never renders.
> - **`finance_api_controller.ex:75`** — `:missing_symbol` can never match, so
>   `"Enter a ticker symbol."` is unreachable.
> - **`integrations/service.ex:16,17,19`** — three specs reference
>   `Integration.t/0`, which the schema never defines. Those specs check nothing.
>
> The rest (`browser_control.ex:268`, `browser.ex:1`, `cli.ex:818 die/2`) are
> benign; the last just wants a `no_return()` spec.
>
> #### Invert the plan
>
> The original sequence — triage all 253, *then* remove `continue-on-error` —
> leaves the gate off for however long the burn-down takes. Do it the other way:
>
> 1. Drop `--format short` from `ci.yml:162`. One line.
> 2. Generate `.dialyzer_ignore.exs` from today's 253 and wire
>    `dialyzer: [ignore_warnings: …]` (dialyxir supports it —
>    `deps/dialyxir/lib/mix/tasks/dialyzer.ex:95`).
> 3. **Flip `continue-on-error: false` immediately.** Any *new* finding fails the
>    build from that moment.
> 4. Fix the four real ones, pruning the baseline as you go.
> 5. **Leave the 232 `unmatched_return`s in the baseline indefinitely.** Rewriting
>    232 call sites to `_ = …` across ~60 files is a wide, no-behavior-change
>    sweep with a green suite the whole way — the exact shape that has bitten this
>    repo before.
>
> #### SHIPPED 08-02 — the gate is on. **Dialyzer blocks CI as of today.**
>
> Done differently than planned, and better. While reading dialyxir's source to
> pick a formatter, the actual mechanism turned up: `Formatter.filter_warnings/3`
> runs **before** formatting, and `filter_warning/3` skips any warning type not
> in `Dialyxir.Warnings.warnings()` — so `:exact_compare` could never be
> baselined away, and every non-default formatter would keep crashing on it.
>
> **So the fix was the source, not the formatter.** The `:exact_compare` finding
> was `sound_studio.ex:152` — `if frame == 0`, where `frame = div(bits, 8) *
> channels` and `parse_fmt/1` already guards `channels > 0` and `bits in [8, 16,
> 24, 32]`. Provably unreachable, and the malformed-header case is already
> answered by `parse_fmt`'s fallback clause. Deleting that branch cleared the
> unknown warning — and with it the crash in **every** formatter, including
> `--format short` and `ignore_file_strict`.
>
> That reverses the correction above: **CI keeps `--format short`.** No formatter
> change was needed at all.
>
> What landed:
>
> 1. `sound_studio.ex` — the dead `frame == 0` branch removed (121 sound tests
>    green).
> 2. **`.dialyzer_ignore.exs`** — 92 `{file, warning_type}` entries covering all
>    252 pre-existing findings, in two clearly separated sections: *accepted
>    noise* (76 files' worth of `:unmatched_return`) and *burn these down* (16
>    entries, with the four confirmed defects named in comments). Coarse rather
>    than line-pinned on purpose — line numbers churn under refactoring, and a
>    filter that silently stops matching teaches nobody anything.
> 3. `mix.exs` — `ignore_warnings: ".dialyzer_ignore.exs"`.
> 4. `ci.yml` — **`continue-on-error` deleted**, job renamed from
>    "Dialyzer (non-blocking)" to "Dialyzer".
>
> **Verified that it actually gates, not just that it passes.** Baseline run:
> `Total errors: 252, Skipped: 252, Unnecessary Skips: 0`, exit 0 — the baseline
> is exact, with no dead entries. Then a deliberately unreachable clause was
> added to `portfolio/returns.ex` (a file with no baseline entry): `Total errors:
> 253, Skipped: 252`, **exit 2**. Probe reverted; back to exit 0.
>
> Steps 4–5 of the plan stand: fix the four real defects and prune their entries.
> The 232 `:unmatched_return`s stay baselined indefinitely.

## 3. Dependency direction has broken down

`mix xref` reports five cycles. The largest compile-connected component spans
105 files and pulls much of the domain and web layer into one recompilation
unit.

The important edges are:

- `Commands` compile-time CRUD generation binds the facade to `Calendar` and
  `Integrations`.
- `Integration` has a necessary compile dependency on the custom `Encrypted`
  Ecto type, which leads to `Vault`.
- `Vault` and `Recovery` read secrets through `BusterClawWeb.Endpoint`
  configuration, creating a core-to-web dependency.
- `Browser.FlowRunner` calls `Commands.Web`, while `Commands.Web` calls the flow
  runner and browser checks.
- `Trading` and `Research` share policy by depending on one another.
- `Music` and `Notifications.Sound` share naming/retargeting behavior by
  depending on one another.
- terminal catalog modules reach back into the top-level terminal facade for
  defaults and protection rules.

The Phoenix web macro's broad compile reach is expected. Core modules depending
back on the web endpoint is not.

**Priority:** P1

> ### VERIFIED 08-02 — **accurate in every particular.** Then mostly fixed.
>
> Every claim re-measured and every one held: 5 cycles (the big one now 110, up
> from 105 — the day's new modules); `Commands` compile-binds exactly `Calendar`
> and `Integrations` via the CRUD loop; `Integration --compile--> Encrypted -->
> Vault`; `Vault`/`Recovery` really do read config through
> `BusterClawWeb.Endpoint`; and the four small cycles are exactly as listed. This
> is the first finding in the document to survive verification intact.
>
> #### What the finding misses: which edge is the keystone
>
> Only **two** compile edges made that 110-node cycle compile-connected, and one
> of them — `Integration --compile--> Encrypted` — **cannot be removed**: Ecto
> resolves schema field types at compile time, so the custom `Encrypted` type
> requires it.
>
> So the removable one was probed: replacing the `BusterClawWeb.Endpoint` module
> alias with the identical literal atom in `vault.ex` and `recovery.ex` — same
> config key, same behaviour, two lines.
>
> ```
> before:  1 compile-connected cycle · 110 nodes (2 compile, 28 export)
> after:   No cycles found           ·  98 nodes (0 compile, 22 export)
> ```
>
> That config-key reference was the **return path**: `Integration → Encrypted →
> Vault → Endpoint → web → … → Integrations → Integration`. It is what made BOTH
> compile edges cyclic. Which means **Phase 1 item 3 alone dissolves the
> recompilation cascade, and item 4 — "replace the compile-time CRUD loop in
> `Commands`" — is optional**, not a prerequisite. That was the most expensive
> item in the phase.
>
> #### SHIPPED
>
> `BusterClaw.RuntimeConfig` — one place for the two runtime facts the desktop
> shell decides (master key, bound port), read without touching the web layer.
> Replaces four reads through the endpoint's config: `Vault`, `Google.Vault`
> (whose `secret_key_base/0` was a byte-identical duplicate of `Vault`'s),
> `Recovery`, and `Dispatcher` (the bound port). `config/{dev,test,runtime}.exs`
> now set `:secret_key_base` and `:local_port` under our own keys alongside the
> endpoint's.
>
> ```
> compile-connected cycles:  1 → 0
> largest cycle:           110 → 72 nodes (1 export edge)
> ```
>
> Cycle *count* went 5 → 6, which is not a regression: the Google-internal cycle
> (`google ↔ client ↔ oauth ↔ self_test`) was always there, absorbed inside the
> 110-node blob. Breaking the blob revealed it.
>
> **Acceptance met:** no module under `lib/buster_claw/` reads configuration
> through a web module (`application.ex` still starts and reconfigures the
> endpoint, which is the app supervisor wiring the web layer — correct).
>
> **Still open from this finding:** the four small cycles (terminal catalog,
> browser flows, Trading↔Research, Music↔Sound) and the now-visible Google one.
> All are export-level, none compile-connected. Phase 1 items 4–6 remain
> unstarted and item 4 is now optional.

## 4. A few modules have become feature containers

The largest modules are not merely long templates. They own unrelated state
machines, I/O, parsing, persistence, asynchronous orchestration, and rendering.
Their tests mirror the same concentration: `trading_live_test.exs` is 1,730
lines and `sound_studio_component_test.exs` is 1,492 lines.

This increases the blast radius of changes and makes behavior difficult to
locate. The answer is to extract cohesive policy and pure transformations first,
not to create arbitrary `Part1`/`Part2` modules or a forest of stateful
LiveComponents.

**Priority:** P1 — **VERIFIED ACCURATE 08-02, and largely FIXED.** See the block
under Finding 3 above and Phase 1 below.

> ### CORRECTION (08-02) — right diagnosis, wrong axis. **Extract by purity, not by feature.**
>
> `TradingLive` already carried maintained section banners, so its seams were
> legible. Mapped before the work started:
>
> | Section | Lines | Size |
> |---|---:|---:|
> | header / mount / moduledoc | 1–123 | 123 |
> | Chat events | 124–157 | **34** |
> | Tabs | 158–205 | **48** |
> | Chat windows | 206–309 | 104 |
> | Research panel | 310–338 | **29** |
> | Order confirmation | 339–381 | **43** |
> | Dashboard events | 382–557 | 176 |
> | Chat stream (PubSub) | 558–927 | 370 |
> | Account asyncs | 928–1087 | 160 |
> | **Snapshot / chart / detail helpers** | 1088–2138 | **1,051** |
> | Order confirmation helpers | 2139–2185 | 47 |
> | **Render** | 2186–3503 | **1,318** |
>
> **Two sections were 68% of the file.** The other nine averaged 123 lines and
> were already separated. This document sized the problem by *responsibility
> count* (9 things mixed) rather than *lines per responsibility* — which led it
> to propose `ChatState` / `TabState` / `ResearchState` / `OrderState`, i.e.
> paying LiveView-lifecycle risk to extract 34, 48, 29, and 43 lines.
>
> The real fracture line was **purity**: ~430 lines inside "Render" and more in
> the helpers block were functions that never touch `socket`, sitting under two
> enormous templates.
>
> **One item here was already true.** Phase 3A's rule *"async task keys include
> the requested account/symbol/range"* is implemented — `start_async({:symbol_bars,
> symbol, interval, from}, …)` at `trading_live.ex:1458` with staleness guards at
> `:1467`, `:1481`, `:1495` via `current_symbol_request/1`. The bare-atom keys
> (`:trading_account`, `:trading_costs`, `:trading_backfill`) are parameterless
> single-flight fetches and are correct as-is. **Nothing to do.**
>
> **The test-file split is a byproduct, not a task.** Most of
> `trading_live_test.exs`'s bulk asserts on rendered output of the pure functions.
> Extract them and the unit tests fall out at microsecond speed; what remains is
> genuine lifecycle coverage. Splitting first would only relocate slow tests.

## 5. Command contracts have several sources of truth

The native command catalog owns names, types, tiers, gating, arguments, and
descriptions. `BusterClaw.Commands` separately repeats the implementation
surface through roughly 160 public delegates so `apply/3` can invoke a function
with the command's name. Invariant tests catch omissions, but every new command
still requires synchronized definitions.

Browser/Tauri actions are repeated across more surfaces:

1. Elixir bridge actions
2. JavaScript dispatch branches
3. Rust command handlers
4. `generate_handler!`
5. `build.rs` registration
6. Tauri capabilities

The Rust ACL test strongly guards the last three. It does not prove that the
Elixir action, JavaScript mapping, argument names, and Rust handler still agree.

**Priority:** P1

> ### VERIFIED 08-02 — **accurate in every particular.** IPC half fixed.
>
> The second finding to survive verification intact, and the numbers reconcile
> exactly: the catalog carries **158 entries**; `Commands` carries **148
> `defdelegate`s + 10 compile-generated CRUD functions = 158**. Every entry is
> checked by `catalog_invariants_test.exs:44` (`function_exported?` per name), so
> omissions really are caught — and every new command really does need both
> declarations. `acl_lockstep.rs`'s own header confirms it guards exactly three
> surfaces ("registered in THREE places in lockstep"), naming two shipped
> incidents where an omission got past dev builds.
>
> The Elixir↔JS gap is real and was unguarded. `bridge.ex:26`'s `@actions` and
> `assets/js/hooks/browser.js`'s `action === "..."` branches agreed *today* (10
> vs 10, identical sets, payload keys aligned) — but nothing checked it.
> `bridge_test.exs` contains zero references to the JS, and `render_hook` never
> executes the hook's real JavaScript. A mismatch surfaces only in a real browser
> as `{error: "unknown browser command"}` from the hook's `else` arm, with every
> Elixir test green. That is the same shape as the rename that severed a hook
> contract while the suite stayed green.
>
> #### SHIPPED
>
> `test/buster_claw/browser/bridge_lockstep_test.exs` — parses both sources as
> text and compares the sets, the same technique `acl_lockstep.rs` uses. Three
> tests: Elixir⊆JS, JS⊆Elixir, and a tripwire asserting neither parser silently
> matched nothing (the lesson from the docs-drift guard, which shipped broken
> because its pattern missed the very line it existed to catch). **Probed in both
> directions** — an Elixir-only action and a JS-only branch each fail it, naming
> the offending action.
>
> #### Recommendation on the rest
>
> **Do not do the native-command registry.** 158 commands, already covered by an
> invariant test that catches exactly the omission it would prevent. The cost of
> the status quo is boilerplate per command; the cost of the change is rewriting
> the single choke point through which all policy, rate limiting and auditing
> flow. Highest blast radius in the document, sold on ergonomics.
>
> The argument-name half of the finding stands unaddressed: the lockstep test
> compares action NAMES, not payload keys. A rename of `"wait_ms"` on either side
> is still a silent break. Worth a follow-up, cheaper than it sounds.

---

# Part II — Dead, suppressed, and compatibility code

## Definite removal or implementation decisions

### Integration polling interval

`polling_interval_minutes` is persisted, validated, exposed in command schemas,
rendered in Settings, and tested. No scheduler reads it; polling is explicitly
on demand.

Choose one:

- Build a real integration scheduler and make the setting operational, or
- Remove the field from the schema, forms, command catalog, tests, and database
  through a new migration.

**Recommendation:** Remove it unless scheduled integration polling has an
approved product requirement. A setting that knowingly does nothing is worse
than an absent setting.

### Inert outbound phone controls

The Home contacts panel renders disabled Text and Call buttons. Outbound calling
does not exist, and Text is not wired from that surface.

**Recommendation:** Remove the controls until the corresponding workflow is
real. Preserve the contact data, not the decorative affordance.

### Dialyzer-proven unreachable clauses

Once Dialyzer itself is reliable, characterize and delete branches it proves
unreachable. Do not bulk-delete all 253 reports: ignored best-effort returns and
impossible matches require different treatment.

## Not dead

- `FinanceApiController` remains an intentional loopback data surface for
  agent-created workspace pages, even though its original bundled page retired.
- `Notifications.SoundGen` is a build/test utility used by
  `scripts/gen_sounds.exs` and audio tests.
- error controllers, application entry points, LiveViews, and route targets may
  appear to have no static callers because Phoenix, OTP, Mix, or Tauri invokes
  them dynamically.

## Compatibility code with an expiration policy

The workspace's deprecated entries and `Pages` retired-file cleanup protect
existing user folders. They should not be mistaken for unused runtime features,
but they also should not remain permanent architecture.

Create a compatibility ledger recording:

- legacy shape
- migration/cleanup owner
- first release containing the migration
- minimum supported upgrade version
- removal release

After the support window closes, remove the legacy branches and tests together.
Never edit or delete already-applied Ecto or Supabase migration history; use
forward migrations when schema cleanup is required.

## Suppression assessment

Credo and Clippy suppressions are few, local, and mostly justified. The MIME
lookup tables are not meaningful cyclomatic-complexity debt, and one flat Rust
command signature is part of the JavaScript IPC contract. The notable
suppression is not a line annotation: it is the non-blocking Dialyzer job.

---

# Part III — Refactoring sequence

## Phase 0 — Make the guardrails truthful

**Goal:** A green build must mean that behavioral documentation and static
analysis are trustworthy.

### Work

1. Correct the generated trading guide to describe the real proposal,
   confirmation, submission, unknown-outcome, and no-automatic-retry behavior.
2. Correct README, architecture, UML, packaging, workspace-path, credential, and
   voice-transport claims.
3. Add semantic contract tests for:
   - trading write capability and confirmation posture
   - current Dispatch projection path
   - packaged credential source and CLI access path
   - generated guide statements derived from current capabilities
4. ~~Upgrade/fix Dialyxir formatting or change CI to a formatter compatible with
   the pinned runtime.~~ **CORRECTED 08-02:** there is no upgrade (1.4.7 is
   latest and is the one that crashes) and `--format github` crashes too. Delete
   `--format short` from `ci.yml:162`; the default formatter is the only one that
   works. See the correction block under Finding 2 for the baseline-first plan
   that replaces steps 5–7.
5. Triage Dialyzer findings by category:
   - impossible/covered patterns
   - actual unhandled errors
   - deliberately ignored best-effort returns
   - inaccurate or missing specs
6. Make intentional ignored returns explicit (`_ = ...`) where appropriate;
   handle consequential return values rather than silencing them.
7. Remove `continue-on-error` only after the report is understood and clean.
8. Export an injectable `handleVoice` entry point, matching the SMS function's
   testable shape. Add tests for signature rejection, PIN pass/fail, XML callback
   escaping, recording fetch/upload, idempotent upsert, transcription update,
   and fail-closed behavior.
9. Add a scheduled or nightly job for the `:browser_engine` suite on a host with
   a supported Chromium-family browser.

### Acceptance

- The generated operating guide agrees with `TradingOrder` behavior.
- The documented API-token workflow works in a packaged application.
- Dialyzer runs to completion and gates CI.
- Voice has direct edge-function tests.
- Real-browser tests run automatically somewhere, even if not on every PR.

---

## Phase 1 — Remove false surfaces and break dependency cycles

**Goal:** No inert product settings, no misleading controls, no core-to-web
dependency, and no xref cycles.

### Work

1. Resolve and remove/implement `polling_interval_minutes` end to end.
2. Remove inert Text/Call controls from Home.
3. Introduce a core secrets/config provider, for example
   `BusterClaw.Secrets.Config`, populated from runtime configuration. `Vault`,
   `Recovery`, and encryption types must not reference `BusterClawWeb.Endpoint`.
4. Replace the compile-time CRUD loop in `Commands` with explicit handlers or a
   declarative handler registry that does not compile domain contexts into the
   facade.
5. Move browser flow execution below the command adapter:

   ```text
   Commands.Web -> Browser.FlowService -> FlowRunner / BackgroundFlow / Checks
   ```

   `FlowRunner` must not call back into `Commands.Web`.
6. Extract shared leaf modules:
   - `AgentToolPolicy` from `Trading`/`Research`
   - `AudioNaming` or `AudioAssetRegistry` from `Music`/`Sound`
   - terminal built-ins/protection policy from `TerminalCommands`/catalog modules
7. Run `mix xref graph --format cycles` after each extraction rather than waiting
   until the end.

### Acceptance

- `mix xref graph --format cycles` reports zero cycles.
- No module under `lib/buster_claw/` reads configuration through a web module.
- `Commands` does not compile against `Calendar` or `Integrations` merely to
  manufacture CRUD function names.
- Integration Settings contains no nonfunctional fields.

---

## Phase 2 — Make the command and IPC contracts declarative

**Goal:** One authoritative declaration per command family, with invariant tests
covering every runtime boundary.

### Native command surface

Extend catalog entries with an explicit handler, such as an MFA or a small
handler struct. `Commands.call/3` remains the sole policy, rate-limit, audit, and
dispatch choke point, but the facade no longer needs one delegate per command.

Requirements:

- native commands still win over composition-skill name collisions
- no runtime atom creation from user input
- every handler returns the existing `{:ok, value} | {:error, reason}` contract
- catalog uniqueness, handler existence, tier, gating, and argument tests remain
- direct internal APIs move to their domain command modules rather than relying
  on facade delegates

### Browser/Tauri surface

Either generate registrations from one manifest or extend contract tests to
cover:

- Elixir bridge action
- JavaScript action-to-invoke mapping
- JavaScript argument names
- Rust handler name/signature contract
- `generate_handler!`
- `build.rs`
- capability allowlists

The manifest must not weaken Tauri's explicit allowlist model. Generation should
produce reviewable files, and the lockstep test should remain as a tripwire.

### Acceptance

- Adding a native command requires one metadata/handler declaration plus its
  implementation, not a catalog edit and facade delegate.
- Adding a browser action cannot pass CI if any Elixir, JS, Rust, registration,
  or capability surface is missing.
- Security policy and audit behavior remain centralized in `Commands.call/3`.

---

## Phase 3 — Split the high-risk modules by responsibility

**Goal:** Thin LiveViews and adapters around cohesive, independently testable
domain modules.

### 3A. Trading and portfolio first

> ### SHIPPED 08-02 — the `TradingLive` purity pass. **This part is done; skip it.**
>
> `TradingLive`: **3,503 → 2,346 lines (−33%)**, without touching a single
> `handle_event`, `assign`, async key, or PubSub subscription.
>
> - **`BusterClawWeb.TradingView`** (new, 474 lines) — the pure view model. State
>   classifiers (`detail_state/2`, the `*_dataset_state` family) and formatters
>   (`money`, `signed_money`, `signed_pct`, `qty`, `money_cents`, `activity_rows`,
>   `transfer_activity`, `included_total`, the `*_class` helpers, `as_of_label`).
>   No socket, no assigns, no process state. Imported by the LiveView so every
>   template call site stayed **byte-identical** — the extraction could not break
>   a template by construction. 27 functions public because they are called from
>   outside; 8 stayed private (verified by call-graph scan, not by guessing).
> - **`BusterClawWeb.TradingAccountCard`** (new, 731 lines) — the accounts panel,
>   the whole right column. The one coupling it had to LiveView internals
>   (`@all_accounts`, used in pattern matches so it must stay a module attribute)
>   is now an explicit `attr`; `last_snapshot/1`, `state_data/1` and
>   `symbol_window/1` moved into `TradingView` where they belonged.
> - **`test/buster_claw_web/live/trading_view_test.exs`** (new) — **37 tests in
>   0.2s**, against 3.8s for the 58 LiveView tests. This is the actual payoff:
>   the empty-vs-stale distinction, the "name the gap" activity notes, and the
>   headline-must-agree-with-the-chart rule are now asserted directly instead of
>   through a rendered page.
>
> Verified: `mix format --check-formatted`, `mix credo --strict` clean,
> **2,180 tests / 0 failures** (2,143 + 37 new), Rust 29 + 5 lockstep green.
>
> **What deliberately did NOT happen, and should stay unscheduled:** the stateful
> `ChatState` / `TabState` / `ResearchState` / `OrderState` slicing below. Those
> sections are 34–48 lines each and sit exactly where the lifecycle risk is.
> Re-measure before scheduling any of it; after this pass the file may not
> warrant it.
>
> ### ALSO SHIPPED 08-02 — three more components out of `TradingLive`.
>
> A second pass after re-measuring the file. Three function components were still
> living in the "helpers" block, each already carrying its own `attr` block —
> components in everything but file placement. A dependency scan confirmed each
> was **fully self-contained**: every private helper it called was defined inside
> its own span, so all three were clean lifts.
>
> - **`BusterClawWeb.TradingResearchPanel`** (218) — `research_card/1` plus its
>   eight pure formatters. Imports `TradingView` for `signed_money`/`as_of_label`.
> - **`BusterClawWeb.TradingTabStrip`** (162) — `trading_tabs/1`, which doubles as
>   the drag-dock target for floating chat windows.
> - **`BusterClawWeb.TradingOrderCard`** (118) — `order_confirm/1` plus the
>   `order_result_*` copy. `settle_order/3` and the transcript helpers stayed in
>   the LiveView: they mutate the socket and write the transcript, which is not
>   the card's job.
>
> `trading_live.ex`: **2,346 → 1,900.** Cumulative for the day: **3,503 → 1,900,
> −46%.**
>
> **Honest note:** unlike the first pass, this one adds no test coverage — these
> are templates, already covered by the 58 LiveView tests. The win is legibility
> and a named boundary per surface, not testability.
>
> **The floor is near.** What remains is the LiveView's actual job: 35
> `handle_event` clauses, 12 async handlers, the PubSub chat stream (370), and
> the symbol-chart fetch orchestration with its staleness guards. Going below
> ~1,700 means splitting the page into two LiveViews, which costs the shared
> state they currently pass for free. **Do not schedule that without a reason
> beyond line count.**
>
> ### ALSO SHIPPED 08-02 — `BusterClaw.Portfolio`, same method. **Done; skip it.**
>
> Chosen over the larger `SoundStudioComponent` (1,933) deliberately: 826 of that
> file's lines are a *single template*, so extracting it buys legibility and no
> correctness. Portfolio is the money math.
>
> The seam was already there and visible once measured — `gain_series/1` is a
> four-line fetch-then-compute wrapper over pure arithmetic. Classifying every
> function as I/O-touching or not found ~110 lines of pure math, **all `defp`,
> all with zero external callers**, so the move cost nothing at the boundary.
>
> - **`BusterClaw.Portfolio.Returns`** (new, 157 lines) — `build_gain_series/2`
>   (gain measured *around* flows, so a deposit never reads as a return),
>   `anomalous?/1` (the ratio-and-floor transfer test), `join_series/2` (splices
>   the broker's realized history onto our own recording without double-counting
>   the overlap, and offsets the recorded segment so the seam is continuous),
>   plus `flows_by_day/1` and the private helpers each depends on.
> - **`test/buster_claw/portfolio/returns_test.exs`** (new) — **21 tests in 0.2s**,
>   previously reachable only by writing snapshot rows first. Covers the cases
>   that would be silent lies if wrong: a deposit netted to zero gain, a
>   withdrawal added back, a flow landing inside a recording *gap* subtracted
>   exactly once, the half-open window at the previous reading, the documented
>   $1,000-into-$200,000 detection limit, and a seam that is continuous rather
>   than a cliff.
>
> `portfolio.ex`: **1,023 → 918 lines.** Call sites are explicitly qualified
> (`Returns.build_gain_series(…)`) rather than imported — unlike the LiveView
> case, here the point is that the dependency direction is *visible*.
>
> Verified: format clean, credo strict clean, **2,201 tests / 0 failures**.
>
> Untouched and still open: `BusterClaw.Trading` (1,270 — two big prompt heredocs
> plus parsers over untrusted model output; `Prompts` and `Parsers` are the
> obvious cheap extractions) and `SoundStudioComponent` (1,933 — a template
> decomposition job, not a purity one). Ask the purity question of each before
> accepting the module trees below.

Recommended extraction:

```text
BusterClaw.Trading
├── ToolPolicy
├── Prompts
├── Parsers
├── AccountSnapshot
├── AccountDetail
├── MarketSweep
└── Cache

BusterClaw.Portfolio
├── Snapshots
├── Flows
├── Returns
├── Anomalies
├── RealizedPnl
└── CostBasis

BusterClawWeb.TradingLive
├── ChatState
├── TabState
├── ResearchState
├── OrderState
├── DashboardViewModel
└── Presentational function components
```

Rules:

- Prompts only construct prompts; parsers only normalize untrusted output.
- Fetch orchestration returns typed domain values, not render-ready maps.
- Portfolio persistence does not depend on LiveView assigns.
- Async task keys include the requested account/symbol/range so stale results
  cannot overwrite current state.
- Order confirmation and unknown-outcome behavior receive characterization tests
  before moving.
- Avoid new LiveComponents unless a region genuinely needs its own lifecycle;
  prefer pure modules and stateless function components.

### 3B. Studio and Home — **first pass 08-03**

> **What shipped, and the honest shape of what is left.**
>
> `StatusLive` **1,420 → 1,346**. Two extractions, neither chosen by line count:
>
> - **`BusterClaw.Notifications.Schedule`** — the timer/alarm/reminder
>   wall-clock arithmetic, which was pure the whole time and simply lived in a
>   LiveView. That meant the only way to ask *"what does 11:30pm mean when it is
>   11:45pm"* was to drive a mount, an event and a form, so nobody had. It now
>   has **11 tests** covering the cases that were never written, including a
>   clock injected through `fire_at/3` so a test can stand at a chosen moment.
> - **`StudioMix.track_end_ms/1,2` and `paste_track/2`** — these existed
>   **twice**, once in `StatusLive` and once in `SoundStudioComponent`, in
>   different shapes and unaware of each other. Two implementations of *"where
>   does this track end"* is one drifting apart later, on a number that decides
>   where audio lands. Consolidated onto the mix, **9 tests** neither copy had.
>
> **The rest of StatusLive's studio cluster was examined and left alone**, which
> is the finding worth recording. `mutate_open_mix`, `step_history`,
> `push_studio_history`, `reset_studio_history`, `zoom_step` are assigns plus
> side effects — undo/redo stack management and `send_update` — which is
> precisely what a LiveView is for. The roadmap's complaint that *"StatusLive
> implements Studio editing"* is largely already satisfied: the editing lives in
> `SoundStudioComponent` and `StudioMix`; what remains here is the state a
> component cannot hold, because the tab's `:if` discards it on every switch.
> Extracting it would move orchestration into a module that then needs the
> socket passed to it — indirection, not separation.
>
> **`SoundStudioComponent` is 1,926 and is a different job.** It is template
> decomposition, not purity extraction — the roadmap says so — and it wants a
> pass of its own rather than being tacked onto this one.
>
> **The lesson this phase has to carry:** `TradingLive` was cut 46% and regrew
> past its own starting complaint within a week. A split buys a rate, not a
> destination, unless something makes the regrowth visible.

Extract a pure `StudioSession` state transition layer for selection, clipboard,
undo/redo, arrangement edits, and trim state. Separate:

- source catalog and filesystem operations
- audio analysis and formatting
- mix mutations
- presentation/view-model shaping
- HEEx sections

`StatusLive` should orchestrate Home-level navigation and subscriptions, not
implement Studio editing, notification parsing, contacts policy, weather
formatting, and chat projection in the same module.

### 3C. Remaining service and adapter hotspots — **CUT 08-03, with reason**

> **Dropped by the roadmap's own argument.** Its verification scorecard records
> Finding 4 as *"right diagnosis, **wrong axis** — sized by responsibility count,
> not lines per responsibility."* Every module below was listed on the wrong
> axis: measured 08-03 they are `PortfolioChart` 996, `Commands.Web` 894, `CLI`
> 867, `TerminalCommands` 795, `Gmail` 739 — mid-sized Elixir modules with
> coherent single jobs, not feature containers. Splitting them buys smaller
> numbers and more indirection, which this document elsewhere explicitly forbids
> ("Do not optimize for line count alone", "No extracted module exists solely to
> reduce line count").
>
> **What would put one back on the list:** a *responsibility* count, not a line
> count. If `Commands.Web` grows a fifth unrelated job, or `CLI` starts holding
> transport policy as well as parsing, split it then — and say which
> responsibility moved, not how many lines did.
>
> The original prescriptions are kept below for whoever makes that case later.

*Cut — retained as reference, not as work:*

- Split `CLI` into parser, shorthand translator, HTTP transport, renderer, and
  process/signal handling.
- Split `Commands.Web` by fetch/download, live co-presence, flows/checks, and
  bookmarks/history after the dependency cycle is gone.
- Split `Google.Gmail` into request operations, MIME construction/parsing,
  attachment handling, and normalized message mapping.
- Split `TerminalCommands` into defaults, catalog codec/migration, store, edit
  changesets, and presentation.
- Split `PortfolioChart` into series preparation, geometry, primary chart,
  symbol chart, and sparkline components.

### Test organization

Split giant test files by behavior, not by arbitrary line ranges. For example:

```text
test/buster_claw_web/live/trading_live/
├── chat_test.exs
├── tabs_test.exs
├── dashboard_test.exs
├── research_test.exs
├── orders_test.exs
└── async_reconciliation_test.exs
```

Keep outcome-oriented selectors and characterization coverage. Moving a function
without changing behavior should not require weakening an assertion.

### Acceptance

- LiveViews primarily initialize assigns, route events, reconcile async results,
  and render composed components.
- Pure parsing, geometry, policy, and state-transition modules can be tested
  without a LiveView process.
- No extracted module exists solely to reduce line count; every module has a
  concise responsibility statement.
- The public command/API behavior remains compatible throughout the phase.

---

## Phase 4 — Consolidate UI and desktop infrastructure

**Goal:** Remove hand-built page duplication, resolve project-rule drift, and
leave source comments focused on durable invariants.

### Browser pages

More than 1,000 lines across browser controllers manually construct standalone
HTML, CSS, forms, and scripts. Move these to:

- HEEx templates or function components
- a shared browser-surface layout
- bundled JavaScript/CSS through the supported asset entry points
- centralized escaping and response headers

Preserve the intentional isolation between Phoenix chrome, sandboxed page
content, and Tauri child webviews.

### Project-guideline reconciliation

Make explicit decisions for each contradiction:

- ~~daisyUI is imported and used despite the repository rule forbidding it~~
  **RESOLVED 08-03 — the rule changed, not the code.** `AGENTS.md` now states the
  convention that was actually in force: daisyUI supplies the primitives and
  theme tokens, the `ic-` utilities and hand-written Tailwind carry the
  Industrial Claw identity on top, and a stock daisyUI look never ships as the
  final design. Migrating off the plugin was the alternative and was declined —
  it is a UI-wide refactor whose only failure mode is visual, which no test can
  guard. The recommendation below (option 1) is superseded.
- production and test files contain nested modules despite the no-nesting rule
- the root template contains inline theme JavaScript
- several templates use raw inputs where the core input component is available

Recommended direction:

1. Migrate daisyUI component classes and theme generation to the existing custom
   Tailwind design system, then remove the plugin.
2. Extract production nested structs/state modules into separate files; move
   reusable test doubles into `test/support` modules with unique names.
3. Move the theme bootstrap to `app.js`, then simplify CSP from a nonce-bearing
   script policy if no other runtime requirement needs the nonce.
4. Use `<.input>` for user-facing Phoenix forms; retain raw hidden fields or
   standalone sandbox-page inputs where the component adds no value.

If the team intentionally wants a different rule, update `AGENTS.md` first and
enforce the new rule consistently. A rule that describes neither the code nor
the desired destination creates noise rather than quality.

### Source archaeology

The source contains roughly 260 references to roadmap phases, findings, incident
dates, and implementation history. Much of that history is valuable, but it
obscures present-day contracts.

Move chronological explanations to ADRs or `daily-growth` records. Keep comments
in source when they explain:

- a current invariant
- a security boundary
- an external protocol constraint
- a non-obvious failure mode that remains possible
- why a tempting simplification would be incorrect today

Remove comments that only say which roadmap phase created a line or on what date
a bug was observed.

### Acceptance

- Browser standalone surfaces share layout/assets instead of repeating document
  shells.
- `AGENTS.md` and the implementation agree.
- Production modules are one module per file.
- Root HEEx contains no custom inline JavaScript.
- Source comments explain current behavior; historical narrative lives in the
  historical record.

---

# Part IV — Execution rules

## Keep every refactor behavior-preserving by default

Each extraction should follow this sequence:

1. Add or confirm characterization coverage.
2. Move one cohesive responsibility behind the existing public API.
3. Run the narrow tests for that responsibility.
4. Run the full relevant language suite.
5. Check xref cycles and compilation impact when module boundaries change.
6. Run `mix precommit` after all changes in the work unit are complete.

Behavior changes—removing an inert setting, correcting an agent policy, changing
a compatibility horizon—must be explicit PR objectives rather than accidental
side effects of a move.

## Do not optimize for line count alone

A 500-line declarative catalog or generated document can be easier to maintain
than five mutually dependent 100-line modules. Extract when doing so creates one
of these outcomes:

- a dependency points in one direction
- policy gains one authoritative owner
- pure logic becomes independently testable
- I/O is isolated behind a boundary
- state transitions become explicit
- duplicated declarations disappear

## Preserve the strong parts

The refactor should retain:

- centralized command policy, rate limiting, and auditing
- integer-cents financial storage
- fail-closed browser and telephony security decisions
- Req as the HTTP client
- explicit Tauri capability allowlists
- workspace ownership and path guards
- detailed outcome-oriented tests
- the functional-core/imperative-shell split already present in the Rust browser
  modules

---

# Recommended order

1. **Phase 0:** truthful runtime guidance, working Dialyzer, voice tests, and an
   automated real-browser lane.
2. **Phase 1:** remove inert surfaces and break all dependency cycles.
3. **Phase 2:** establish authoritative command and IPC registries.
4. **Phase 3A:** refactor Trading and Portfolio behind their existing APIs.
5. **Phase 3B:** refactor Studio and Home.
6. **Phase 3C:** refactor CLI, Web commands, Gmail, Terminal Commands, and chart
   presentation.
7. **Phase 4:** consolidate browser pages, resolve guideline drift, and move
   source archaeology into ADRs.

The first implementation PR should be Phase 0 only. Splitting the largest files
before the contracts and dependency directions are trustworthy would redistribute
complexity without reducing it.

---

## Progress (08-02)

**Done:**

- **Phase 3A, `TradingLive`** — see the SHIPPED blocks in 3A. **3,503 → 1,900
  (−46%)** across two passes: `TradingView` + `TradingAccountCard` (purity), then
  `TradingResearchPanel` + `TradingTabStrip` + `TradingOrderCard` (components).
  37 new unit tests. Near its floor — see the note there before going further.
- **Phase 3A, `Portfolio` purity pass** — 1,023 → 918 lines;
  `Portfolio.Returns` extracted (the gain arithmetic); 21 new unit tests.
  Suite 2,201/0.
- **Dialyzer gate** — `.dialyzer_ignore.exs` baseline (252 findings, two
  sections) + `continue-on-error` deleted. **Dialyzer blocks CI as of 08-02**,
  verified by probe rather than assumed. See the SHIPPED block under Finding 2.

**Verified-and-dismissed** (do not spend time here):

- Finding 1's headline — two prompts, both correct; the literal fix would open a
  hole. Only `introduction.ex:607-608` needs a two-sentence referral edit (P2).
- Phase 3A's async-key rule — already implemented at `trading_live.ex:1458`.
- Phase 0 item 4's "upgrade Dialyxir" — no such upgrade exists.
- Phase 3's "split the giant test file" as separate work — it is a byproduct of
  the purity extraction.
- Phase 0 item 4's formatter change — **unnecessary after all.** The
  `:exact_compare` crash was a code defect, not a tooling one; fixing the source
  un-crashed every formatter and CI keeps `--format short`.

- **The `sigint` bug — FIXED 08-02.** Not fixable as designed: SIGINT is
  reserved by the BEAM's break handler, `:os.set_signal/2` rejects `:sigint` as
  an invalid signal name, and nothing runs on arrival — not a handler, not
  `System.at_exit/1` (verified empirically: SIGINT drops into the BREAK menu and
  the process survives). So the dead trap was replaced with SIGTERM/SIGHUP
  handling — the endings that *are* catchable, i.e. a `kill`, a closed terminal,
  a torn-down packaged shell — and the six places that promised Ctrl-C stands
  down were corrected, including the banner printed on every `on-duty`. Three
  regression tests pin the banner and the help text together. `{cli.ex, :call}`
  pruned from the Dialyzer baseline; back to `Unnecessary Skips: 0`.

- **All four confirmed Dialyzer defects — FIXED 08-02.** Beyond the `sigint`
  one: `cli.ex`'s refused-connection clause matched httpc's `{:failed_connect,
  _}` and now matches `%Req.TransportError{reason: :econnrefused}` (shape
  verified against a real refused connection), restoring the *"is `mix
  phx.server` running?"* line that had been silently lost since the move to Req;
  `finance_api_controller.ex`'s unreachable `:missing_symbol` clause deleted
  (`lookup/2` already answers an empty query, with better copy); and
  `integrations/service.ex`'s three vacuous specs made real by declaring
  `@type t` on the Integration schema, which Ecto does not generate. Baseline:
  **252 → 247 findings, 16 → 12 non-noise entries**, `Unnecessary Skips: 0`
  throughout. Six new regression tests.

- **README credential path — FIXED 08-02** (Finding 1's P1). Worse than the
  finding described: the README's recipe was wrong in *both* environments, not
  just the packaged one. `desktop/tauri/src/main.rs` (`ensure_secret`) migrates
  any plaintext token into the Keychain and then **deletes the file**, so
  `cat …/api_token` cannot work on a packaged install; and `config/dev.exs`
  sets a fixed literal, so dev never writes that file either. Nothing in the
  codebase writes it. Replaced with a three-row table covering in-app terminal
  (already exported), external shell (`security find-generic-password -s
  BusterClaw -a api_token -w`), and dev (the literal). `cli.ex`'s moduledoc and
  the vestigial `read_token_file/0` are now documented as legacy rather than
  current. `scripts/check_docs_drift.sh` gained a guard so it cannot come back —
  **and the guard's first version silently missed the real line**, because the
  README escaped the space (`Application\ Support`); caught by probing it with
  the actual bad line rather than trusting it.

- **Finding 1's P2 prose drift — FIXED 08-02, and it was more than prose.**
  `shift/Dispatch.md` corrected in four docs (the projection is top-level
  `Dispatch.md`; the dated diary moved to `.buster-claw/dispatch/<date>/`), plus
  two references the finding never listed. The voice edge function's header
  claimed the Mac "subscribes via Realtime" — it polls PostgREST, and
  `Telephony.Relay`'s own moduledoc explains why (a subscription can't replay
  rows that arrived while the laptop slept). Playwright removed from the
  packaging doc's deferred list.

  The UML section was the real find: the supervision diagram was missing
  **fifteen children** (Browser.Capture/Bridge, RateLimiter, Dispatcher,
  Analyzer, Telephony.Drain, the schedulers, both chat processes, the four
  BrowserControl supervisors/registries, the screencast pair) and still showed a
  `DNSCluster` that no longer exists; the domain list predated Trading,
  Portfolio, Telephony, Music and BrowserControl; and `Commands.call/2` is
  `call/3` — wrong in the diagram and in three moduledocs. Sections 1 and 2
  re-derived from `lib/`; the header now says which sections were re-checked and
  which still date from 06-14, rather than implying the whole file is current.

- **Findings 3 and 5 — VERIFIED 08-02, both fully accurate.** The only two that
  survived verification intact, and notably the two the reviewer built from
  tooling output rather than prose. Phase 1 item 3 shipped
  (`BusterClaw.RuntimeConfig`) and took compile-connected cycles **1 → 0**;
  Phase 2's IPC half shipped (bridge lockstep test). See the blocks under each
  finding.

- **Evening batch (08-02): Phase 0 items 1–3 and ALL of Phase 1 closed.**
  - The guide's trading referral corrected (`introduction.ex`) with a contract
    test pinning the posture: the prohibition must survive every rewrite,
    "execution is disabled" may never return, and the guide must agree with
    `Trading.@system_prompt` about whose click reaches the broker.
  - All 12 remaining baseline entries diagnosed: 3 dead (deleted — probe_steps'
    leftover launch clause, a pre-0.5-Req header shape, a backoff-masking
    fallback), 9 deliberate (justified in the baseline by name: corrupt-data
    degradation ×3, fail-closed webhook compare, unknown-OS error, a macro
    artifact, LiveView crash guards ×2, an honest no_return). 247 → 244.
  - `polling_interval_minutes` removed end to end with a forward migration —
    the roadmap's own recommendation, executed. Text/Call controls verified
    already gone.
  - **Cycles: 6 → 2, and both survivors are accepted with reasons.**
    `AgentToolPolicy` and `AudioName` leaves broke Trading↔Research and
    Music↔Sound; `Portfolio.Series` took the windowing math out of the chart
    (the last core→web edge — **no `lib/buster_claw` file participates in any
    cross-layer cycle now**); FlowRunner's default executor moved to its one
    caller (the named acceptance "FlowRunner must not call back into
    Commands.Web" holds); `TerminalCommands.Builtins` took the shipped catalog
    and protection model. Remaining: the 68-file web cycle (Phoenix-inherent
    router↔LiveView↔verified-routes) and the Google 4-ring (OAuth persisting
    through its parent context — idiomatic, runtime-only, and breaking it would
    relocate a PubSub topic for a number's sake).

**Next, in order:**

1. **Phase 3B/3C** — `SoundStudioComponent` (1,933, template decomposition),
   `StatusLive` (1,400), then CLI / Commands.Web / Gmail / TerminalCommands /
   PortfolioChart. Purity-first each time; measure before cutting.
2. **Phase 4** — nested-modules extraction (4 files), inline theme JS, the
   daisyUI decision (recommend the `AGENTS.md` route), browser-page
   consolidation. Skip the 260-comment archaeology sweep (cut with reason).
3. **Phase 0 items 8–9** — voice edge-function tests; a scheduled
   `:browser_engine` lane (ubuntu-latest + chromium is plausible without new
   hardware).
4. **UML sections 3–5** and the payload-key lockstep.
5. ~~The 12 remaining baseline entries~~ **done, see above.** — eight `:pattern_match_cov`, three
   `:pattern_match`, one `:no_return` (that last one honest: `stand_down/2`,
   its closure, and `die/2` all end in `System.halt/1`). These have been
   *classified*, not *diagnosed* — none is known to be a defect and none is
   known not to be. Same treatment as the four above: read the code, decide
   whether Dialyzer is right, fix or justify.
2. **UML sections 3–5** — the Ecto schema diagrams and the remaining flows still
   date from 06-14 and were not re-checked. Given how far sections 1 and 2 had
   drifted, assume these have too.
3. **The five remaining cycles** — terminal catalog, browser flows,
   Trading↔Research, Music↔Sound, and the newly-visible Google one. All
   export-level, none compile-connected, so the recompilation cost is already
   paid. Phase 1 items 4–6, with item 4 now optional (see Finding 3).
4. **Payload-key lockstep** — the bridge test compares action NAMES; a rename of
   `"wait_ms"` on either side is still silent. Cheaper than it sounds.

---

## Verification scorecard (all five findings, 08-02)

| Finding | Numbers | Conclusions |
|---|---|---|
| 1 — behavioural docs | exact | **wrong** — two prompts, both correct; the literal fix was a security regression. One real P1 (README credentials), rest P2 |
| 2 — Dialyzer suppressed | exact | right, **~10× smaller** than implied (232/253 one noise class); hid a live bug |
| 3 — dependency direction | exact | **fully accurate** |
| 4 — feature-container modules | exact | right diagnosis, **wrong axis** (sized by responsibility count, not lines per responsibility) |
| 5 — command contracts | exact | **fully accurate** |

Every structural measurement in the document held. Three of five conclusions did
not. The two that survived intact — 3 and 5 — are the two derived from tooling
output (`mix xref`, the ACL test's own header) rather than from reading prose.
That is the reusable lesson: this reviewer was reliable exactly where it ran
something, and unreliable exactly where it inferred.
