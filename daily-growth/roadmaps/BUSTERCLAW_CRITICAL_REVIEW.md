# BusterClaw — Critical Review

**An outside read of the whole repository, and the plan that answers it.** Part I is the
review as written. Part II is the remediation roadmap it produced.

**Reviewed 2026-08-06 · Roadmap proposed 2026-08-06 · Status: PROPOSED.**

> ### What has happened since — read this first
>
> **Part I is a dated review and is preserved exactly as written.** Its findings
> were true on 2026-08-06; several are no longer true, and rewriting them would
> destroy the record of what an outside read actually found. Nothing in Part I has
> been edited.
>
> **Part II is a live plan and IS updated.** Since it was written:
>
> - **2026-08-08 — the trading stack was deleted** (`293f47f`): Trading, Portfolio,
>   MarketData, Watchlist and Chart Build, ~22,000 lines. **This resolves Phase 5
>   entirely** and shrinks Phases 0 and 4.
> - **2026-08-08 — the extension mechanism was deleted** (`a89163e`) after one day,
>   having been built to re-home Trading.
> - **The clean-clone test gap the review predicted was found and fixed** — a
>   workspace assertion that passed only on machines carrying a gitignored build
>   artifact.
>
> The subtraction the review asked for **has begun and went further than proposed**:
> the review recommended putting Trading behind Labs; the operator deleted it.

> ### The verdict in one paragraph
>
> BusterClaw is an ambitious, thoughtful prototype that **mistakes breadth for product
> maturity**. Its strongest idea is excellent: give a terminal agent a durable queue,
> canonical command surface, local workspace, and receipts for consequential actions.
> Instead, that core is buried beneath browser, email, calendar, trading, phone, audio,
> finance, shader, journal, and tutorial products. The launch roadmap admits users cannot
> answer *"what is BusterClaw?"* because each surface pitches something different. **That is
> evidence that prioritization has failed at scale.**

---

## Contents

**Part I — The review**

- [1. What the architecture gets right](#1-what-the-architecture-gets-right)
- [2. Too large for its product stage](#2-too-large-for-its-product-stage)
- [3. The command surface](#3-the-command-surface)
- [4. The durable work loop](#4-the-durable-work-loop)
- [5. Security — the best engineering and the biggest overclaim](#5-security--the-best-engineering-and-the-biggest-overclaim)
- [6. The autonomous-agent posture](#6-the-autonomous-agent-posture)
- [7. Trading — capability outrunning assurance](#7-trading--capability-outrunning-assurance)
- [8. Testing — a strength that needs calibration](#8-testing--a-strength-that-needs-calibration)
- [9. The release story](#9-the-release-story)
- [10. Data evolution](#10-data-evolution)
- [11. The interface](#11-the-interface)
- [12. The remedy](#12-the-remedy)
- [13. The honest summary](#13-the-honest-summary)

**Part II — [Remediation roadmap](#part-ii--remediation-roadmap)**

- [Operating rules](#operating-rules)
- [Phase 0 — Make the product honest and focused](#phase-0--make-the-product-honest-and-focused)
- [Phase 1 — Turn the trust story into enforceable behavior](#phase-1--turn-the-trust-story-into-enforceable-behavior)
- [Phase 2 — Prove the command and prompt-injection boundaries](#phase-2--prove-the-command-and-prompt-injection-boundaries)
- [Phase 3 — Give local data a safe upgrade path](#phase-3--give-local-data-a-safe-upgrade-path)
- [Phase 4 — Reduce architectural change amplification](#phase-4--reduce-architectural-change-amplification)
- [Phase 5 — Contain or rebuild Trading](#phase-5--contain-or-rebuild-trading)
- [Phase 6 — Make the packaged application the tested product](#phase-6--make-the-packaged-application-the-tested-product)
- [Phase 7 — Make failures supportable and public release measurable](#phase-7--make-failures-supportable-and-public-release-measurable)
- [Milestones](#milestones)
- [Finding-to-phase map](#finding-to-phase-map)
- [Completion gate for every phase](#completion-gate-for-every-phase)

---

# Part I — The review

## 1. What the architecture gets right

**The underlying architecture contains genuinely good decisions.**

- **Phoenix and OTP suit an always-running local coordinator.** Supervised processes,
  registries, bounded task fan-out, monitored agent runs, and PubSub are used deliberately
  rather than decoratively.
- **SQLite is reasonable** for structured local state, while **Markdown** gives users
  inspectable, portable artifacts.
- **The Tauri shell** lets Phoenix own most interface state while Rust handles the native
  window, PTY, keychain, and webviews. `Req` is consistently used for HTTP.
- **The command catalog gives the CLI and HTTP API one dispatch path** — exactly where
  policy, rate limiting, and auditing should converge.
- **The Dispatcher shows careful failure thinking.** It serializes unattended runs, applies
  cooldowns and run caps, monitors crashes, reclaims orphaned work, and fails an entire
  batch to untrusted provenance when any open item is untrusted.

> These are not beginner choices. They show an author who understands **concurrency and
> threat boundaries**.

## 2. Too large for its product stage

Unfortunately, those good primitives are carrying a codebase too large for its product
stage.

| Measure | Count |
|---|---|
| Lines across app, tests, JavaScript, native source | **~136,000** |
| Elixir source files | 324 |
| Migrations | 53 |
| Commands | 150+ |

**Important boundaries collapse in enormous modules.**

| Module | Lines |
|---|---|
| `TradingLive` | **2,575** |
| `ExplorePanel` | 1,812 |
| `StatusLive` | 1,415 |
| `Agent.Chat` | 1,375 |
| `Trading` | 1,374 |
| `PhoneLive` | 1,275 |
| `SoundStudioComponent` | 1,235 |

`StatusLive` coordinates chat, contacts, telephony, notifications, weather, music playback,
studio editing, notes, calendar, shaders, and Explore. `TradingLive` handles dashboard
state, multiple conversation types, order proposals, chart data, portfolio history, tabs,
streaming, and a huge template.

> **The roadmap says `TradingLive` was cut from 3,503 to 1,900 lines and then grew back.**
> That proves this is not a one-time cleanup problem; **the architecture lacks a force that
> keeps responsibilities separated.**

## 3. The command surface

The command surface has a similar problem in miniature. A single catalog is valuable, but
**150-plus commands** spanning documents, mail, browser control, finance, telephony,
orchestration, skills, and system actions become their own platform.

Catalog metadata must correctly classify every command's tier, mutation type, gated status,
arguments, documentation, rate limit, and implementation. Generated invariants help, yet the
roadmap concedes **there is no exhaustive caller-by-command authorization matrix**. Adding
one misclassified command can silently punch through the product's defining trust boundary.

Composition skills correctly redispatch each step through policy, but **seeded command
catalogs do not upgrade existing installations**. Therefore a later correction to a default
gate may reach fresh installs while leaving early users on stale security metadata.

> The architecture **centralizes authority, then weakens that benefit** through an unmanaged
> configuration lifecycle.

## 4. The durable work loop

**BusterClaw's most convincing feature — but the truth is more qualified than the pitch.**

What is real: queue items survive crashes, work is claimed transactionally, orphaned jobs
are reclaimed, budgets stop unattended shifts, and the workspace projection gives agents a
legible `Dispatch.md`. This is a strong model.

Yet the agent still receives **prose** telling it how to behave, including instructions to
treat mail as data and avoid embedded commands. Policy enforcement catches gated actions,
but a hostile request can still induce:

- extensive safe-tier activity,
- data disclosure through permitted reads,
- token spending,
- damaging actions that were **classified incorrectly**.

The system has **no dedicated hostile-email, hostile-page, or hostile-SMS prompt-injection
regression suite**. It also aggregates provenance at the open-pool level rather than binding
it per item — safely over-restricting trusted work, but showing that the queue's security
identity is not fully modeled.

> The loop is **durable operationally**; its **semantic safety remains dependent on prompts
> and catalog correctness.**

## 5. Security — the best engineering and the biggest overclaim

### What is genuinely good

The positive work is substantial:

- Caller trust derives from **distinct tokens** rather than routes; comparisons are
  **timing-safe**.
- Restricted and gated actions pass through **central policy**; operator rules may **tighten
  but not loosen** the baseline.
- Webhooks **verify signatures and fail closed**.
- URL fetching **resolves, vets, and pins** addresses across redirects.
- Browser content is **isolated** from Tauri commands; file routes use **path guards**;
  secrets are **encrypted**.
- Sentinel **redacts by key name and value shape**, including tokens, cards, and phone PINs.
- The local-trust document even records **uncomfortable accepted risks**, such as built-in
  agent web tools bypassing the application's SSRF and audit stack.

> That candor is excellent. **Many mature projects never map their boundaries this clearly.**

### Where the language outruns the implementation

> **`Sentinel.Pending` explicitly calls itself an in-memory stub.** It retains at most 100
> refused actions, loses them on restart, and provides list, count, and clear — **no
> approve, deny, replay, persistence, or durable link to the original request.** The
> interface and documentation call these *"pending approvals,"* although **approval is
> impossible.**

Sentinel event persistence is **intentionally best-effort**: database errors are logged and
swallowed so the action proceeds. Read commands are skipped to keep the feed concise.
Consequently, claims that *every* command or consequential action receives a full audit
trail **are not strict guarantees**.

This matters because **auditability is not a supporting feature; it is the product's central
promise.** If the audit write can disappear while the mutation succeeds, the architecture
needs a **transactional outbox** or another durable coupling — not reassuring copy.

> Until then, BusterClaw offers **useful observability, not complete receipts.**

## 6. The autonomous-agent posture

**This needs daylight.**

| Harness | Effective posture |
|---|---|
| **Claude** | Runs commonly default to `bypassPermissions` |
| **Codex** | Translated to `approvalPolicy: "never"` in a workspace-write sandbox — safer than unrestricted, but still removes interactive judgment |
| **OpenCode** | Auto mode approves everything; missing-agent behavior can **fail open** to an unconstrained default |

BusterClaw detects a warning string and rejects the result — **a clever but brittle safety
mechanism tied to external wording.**

These choices may be defensible for unattended execution, yet:

- **First-run disclosure is absent.**
- **The emergency stop exists as a filesystem sentinel, not a prominent interface control.**
- Several powerful loopback routes are **deliberately unauthenticated** because the app binds
  locally — even though malicious local software and browser-origin mistakes are part of the
  realistic threat model.

> The security story currently asks the operator to **admire policy controls without clearly
> explaining how aggressively the underlying harnesses are configured to act.**

## 7. Trading — capability outrunning assurance

**The clearest example in the codebase.**

The order flow has meaningful safeguards: broker reads are allowlisted, proposals must appear
in a fenced block, values are parsed into a struct, displayed confirmation comes from parsed
data, submission is a separate one-shot run, and confirmed payloads cannot be replayed.

Still:

- **A model transcribes account balances into the permanent portfolio ledger.** A wrong
  number can become **irreversible history** because Robinhood does not provide equivalent
  historical account values.
- **The final order hop remains another Claude run instructed not to double-submit** — rather
  than an idempotent, application-owned broker call.
- **Account identity relies heavily on the last four digits.** Collisions fail closed, but
  that is a guard, not stable identity.

> The model has been removed from **arbitrary execution**, not from the **financial data
> path**. Putting this surface in primary navigation lends experimental machinery an
> authority it has not earned.

## 8. Testing — a strength that needs calibration

| Suite | Result |
|---|---|
| Elixir tests | **2,772 run, zero failures** |
| JavaScript tests | **133 run, zero failures** |
| Rust | Formatting, lint, unit, and **ACL lockstep** gates in CI |
| Real Chromium | Runs on a **separate schedule** |

The suites cover malformed inputs, crashes, timeout cleanup, range handling, path traversal,
redaction, policy decisions, rate limits, backend parity, portfolio anomalies, webhook
failures, and LiveView interactions. **Excellent volume and often thoughtful boundary
coverage.**

**However:**

- **22 browser-engine tests remain excluded** from the ordinary Elixir run.
- Full **end-to-end DOM coverage is missing**.
- **Packaged behavior is less proven than source behavior.**
- There are **no soak, battery, accessibility, full-disk, migration-from-real-install, or
  prompt-injection suites.**

> During my green run, **GenServers crashed, Ecto sandbox ownership errors appeared,
> connections disconnected, and spawned processes raised.** Some noise is deliberately
> induced, but **green output should not look indistinguishable from an incident.**

## 9. The release story

**Even less mature.** The active roadmap says signing and hardened-runtime work is largely
written but **not fully exercised**, notarization acceptance remains open, a clean-clone
build has not been proven, first-launch scenarios remain unchecked, and the supported macOS
floor is uncertain.

Public distribution lacks: **an updater, crash reporting, a user-facing error surface, a
diagnostic bundle, a privacy policy, terms, and a working download page.** Google
verification is unresolved. The README says the current build is **Intel-only** while release
automation describes **two architectures** — another sign that implementation, status, and
front-door documentation are moving at different speeds.

> **Most damningly: the repository produced empty DMGs for six days while five
> source-oriented CI jobs remained green.** Artifact assertions were added afterward, which
> is good, but the episode shows a recurring habit: **elaborate internal correctness precedes
> the shortest real-world acceptance test.**

## 10. Data evolution

**Another quiet threat.** Fifty-three migrations already record considerable feature churn,
including creating and later dropping orchestration, wallet, and order-workflow structures.

Database migrations at least have an established mechanism. **Workspace seeds do not.**
Skills, jobs, policy files, trusted-sender lists, agent settings, command catalogs, and MCP
configuration use **"write if absent"** — so an untouched default becomes indistinguishable
from an operator edit.

- A safer policy or corrected command definition shipped later **may never reach an existing
  user**.
- Overwriting **risks destroying operator-owned configuration**.

This is especially serious because **the workspace is advertised as portable and
operator-controlled.** A versioned seed manifest, checksums, merge strategy, or code-enforced
baseline is needed **before the first cohort accumulates permanent local state.**

> Otherwise, upgrades will **update binaries while leaving behavior frozen in yesterday's
> files.**

## 11. The interface

The interface code shows **strong visual intent** — custom industrial styling, WebGPU
backgrounds, polished empty states, thoughtful keyboard behavior, detailed micro-interactions,
and graceful fallbacks. **That craft is real.**

**It is also being spent on surfaces that should not be prominent.**

- `PhoneLive` contains **1,275 lines** although a normal user has no provisioned number and
  the dialpad remains **decorative**.
- **Voice largely directs users elsewhere.**
- **Explore includes stubs.**
- **Trading remains safety-sensitive.**
- **Sound Studio is impressive but unrelated to the core promise.**

Continuous shaders, animation, long-lived LiveViews, audio, embedded browsers, and background
agents all compete for battery and memory, yet **long-session measurements are absent**.

> **A beautiful incomplete feature is worse than a hidden experiment because polish signals
> reliability.** BusterClaw's visual confidence exceeds its operational confidence,
> encouraging users to explore precisely the areas that deserve caution.

## 12. The remedy

**The remedy is focus, not another subsystem.**

1. **Freeze feature development.** Define BusterClaw as the durable local agent queue,
   canonical command surface, browser-and-terminal body, workspace, and trustworthy audit
   record. Make home, onboarding, README, and website tell that **same** story.
2. **Put Phone, Trading, Voice, Studio, and unfinished Explore content behind explicit Labs
   controls** or remove them from release builds.
3. **Convert pending refusals into a durable approval-and-replay workflow.**
4. **Couple mutations to audit persistence**, add a **visible kill switch**, **disclose
   harness permission modes**, and **generate the full caller-by-command authorization
   matrix**.
5. **Build hostile-content tests before adding integrations.**
6. **Break the largest LiveViews by responsibility**, establish budgets for module growth,
   **version seeded defaults**, and test migrations from real historical installations.
7. **Require signed, quarantined, offline, first-launch, and update acceptance on both
   architectures.** Treat packaged smokes as **the product gate**, not an optional epilogue
   to source tests.

## 13. The honest summary

> **BusterClaw is neither fraudulent nor incompetent. It is more concerning than that: it is
> talented, inventive, self-aware, and dangerously undisciplined.**

The repository demonstrates enough engineering ability to build a dependable product, but
also enough appetite to **avoid finishing one by continually widening it**. Its strongest
mechanisms — **durable dispatch, central commands, provenance tiers, and local ownership** —
deserve a **narrower application and harder guarantees**.

Today, BusterClaw is an impressive private workshop whose documentation sometimes **presents
future controls as present trust**.

| Audience | Ready? |
|---|---|
| Technical beta among informed collaborators | **Acceptable with blunt disclosure** |
| Strangers, financial workflows, unattended email, public distribution | **Not ready** |

> The path forward is **subtraction, exercised release evidence, and promises rewritten to
> match what the code can guarantee today.**

---

# Part II — Remediation roadmap

**Status:** Proposed **2026-08-06** · **Phase 5 resolved by deletion 2026-08-08.** This roadmap answers the findings above.

> `LAUNCH_ROADMAP.md` remains the authority for **Apple signing, notarization, packaging, and
> public-release mechanics**; this document defines the **product, trust, architecture, and
> reliability** work that must feed that release gate.

**The sequence is intentional.** BusterClaw should first become **honest** about what exists,
then make its security promises **enforceable**, then **reduce structural risk**. New features
do not belong in this plan. Work that does not close a finding, remove a surface, or produce
acceptance evidence waits until the relevant phase exits.

## Operating rules

| # | Rule | What it means |
|---|---|---|
| 1 | **Freeze top-level scope** | No new dock destination, integration family, agent backend, command family, or autonomous workflow until Phases 0–3 are complete. |
| 2 | **Prefer subtraction** | Moving an unfinished surface behind Labs is a valid fix. Adding explanatory polish to an unfinished surface is not. |
| 3 | **Separate written, tested, and exercised** | A checkbox closes only when the implementation exists, automated tests cover its contract, and any required packaged/manual proof has been recorded. |
| 4 | **Make safety claims mechanically true** | If a guarantee cannot be enforced, narrow the wording instead of relying on prompts, labels, or intent. |
| 5 | **Protect operator ownership** | Workspace migrations may update untouched defaults, but must never silently overwrite operator edits. |
| 6 | **Keep one source of truth** | When this roadmap overlaps an existing launch item, link to that item rather than inventing a second status. |

---

## Phase 0 — Make the product honest and focused

> **Priority: P0.** Complete **before the next external build**.

### Work

- [ ] **Lock one product sentence:** *BusterClaw is a local runtime that gives a terminal
      agent a durable work queue, controlled tools, and verifiable receipts.* Use the final
      agreed wording in the README, website, setup wizard, home screen, and Manual.
- [ ] **Make the durable queue the primary first-run path.** Explain home chat as an
      interactive mode and the unattended Dispatcher as an advanced mode; do not present two
      unrelated front doors.
- [ ] **Add a single Labs capability flag** and move Phone, Voice, Sound Studio, unfinished
      Explore panels, and any decorative control behind it. Labs must **default off** for a
      fresh production install. *(Trading left this list on 08-08 — deleted, not flagged.)*
- [x] ~~**Keep read-only Trading visible only if** it is clearly labeled non-authoritative
      and experimental.~~ **Resolved 08-08 by deletion.**
- [ ] **Remove or rewrite every claim** that says all commands are audited, refusals are
      actionable approvals, or the app contains no AI in a way that hides the required
      external agent.
- [ ] **Update the setup and introduction guides** to match the actual route structure,
      wizard steps, permission requirements, and supported features.
- [ ] **Add a small docs assertion** that the canonical product sentence and support
      requirements appear consistently at each front door.

### Exit criteria

- A new user can answer **what BusterClaw does** after the first screen.
- **No default navigation destination** is a stub, dead end, decorative prototype, or
  safety-sensitive experiment.
- Product copy distinguishes **current guarantees, accepted risks, and planned work**.
- Existing launch items **VI-a through VI-g** and **G-23, G-24, G-36, G-37, G-38** are
  reconciled against this phase.

---

## Phase 1 — Turn the trust story into enforceable behavior

> **Priority: P0.** Complete **before unattended external beta use**.

### 1.1 Durable approvals

- [ ] Replace `BusterClaw.Sentinel.Pending` with an **Ecto-backed pending-action schema** and
      explicit state machine: `pending → executing → approved | denied | expired | failed`.
- [ ] **Persist** command name, original caller, tier, source, expiration, a canonical payload
      digest, redacted display arguments, and encrypted replay arguments. **Never** store
      replayable secrets in plaintext or show them in the LiveView.
- [ ] Add **approve and deny controls** to Security. Approval must authorize **exactly one
      immutable command payload**, not convert the original caller into a generally trusted
      caller.
- [ ] **Claim an approval atomically** before execution so double-clicks and reconnects cannot
      replay it. Where an external provider supports idempotency keys, derive one from the
      pending-action ID.
- [ ] **Record intent before an external action**, then record success, failure, and any
      provider identifier afterward. If the process dies between intent and outcome, show an
      explicit **unknown/reconciliation** state rather than claiming success or silently
      retrying.
- [ ] **Expire stale approvals and preserve their audit history.** Clearing the UI must
      acknowledge records, **not delete evidence**.

### 1.2 Audit guarantees

- [ ] **Define the exact audit contract:** which reads, mutations, sends, denials, agent runs,
      and external fetches are recorded; which built-in harness actions remain outside
      visibility.
- [ ] **Couple** application-owned database mutations and audit events in the same
      `Ecto.Multi` transaction where practical.
- [ ] For filesystem and external mutations, use a **durable intent/outcome record**. Do not
      describe this as exactly-once execution unless the downstream operation provides an
      idempotency or reconciliation mechanism.
- [ ] **Surface audit persistence failures prominently.** A background log line is
      insufficient when receipts are the product.
- [ ] Add **retention, export, and integrity** behavior. An operator must know whether events
      can be pruned and whether an export is complete.

### 1.3 Operator control and disclosure

- [ ] Add a **visible emergency-stop control available from every main surface**. It must stop
      the active shift, terminate supervised agent process groups, prevent new Dispatcher
      runs, and show whether the disk `STOP` sentinel is engaged.
- [ ] **Disclose the selected harness, model, sandbox, tool profile, and approval mode** before
      the first chat or unattended run. **Require acknowledgement** when the effective mode
      bypasses interactive approval.
- [ ] **Put Security in primary navigation** and show badges for pending actions, critical
      refusals, and audit-write failures.
- [ ] **Re-review every unauthenticated loopback route.** Require a scoped token for mutations
      wherever the native webview can supply one; document the remaining read-only exceptions
      and their threat assumptions.

### Exit criteria

- A refused gated command can be **reviewed, approved once, executed once, and traced**
  through an immutable lifecycle **after restart**.
- A **failed audit write cannot pass invisibly** as a fully receipted action.
- The **emergency stop works** during a live agent subprocess and a Dispatcher run.
- **Permission posture is visible before execution.**
- Existing launch items **G-29 through G-33** are closed by **tests and exercised evidence**,
  not copy alone.

---

## Phase 2 — Prove the command and prompt-injection boundaries

> **Priority: P0.** Complete **before expanding integrations or trusted senders**.

### Work

- [ ] **Generate an exhaustive test over every catalog entry and each caller** (`trusted`,
      `agent_untrusted`, `agent`, `mcp`). Assert the expected allow/approval/block result and
      **fail when a new command lacks an explicit classification**.
- [ ] **Strengthen catalog invariants** so every mutation, outbound send, delete, share,
      purchase, and settings change declares type, tier, gating, rate limit, and audit
      behavior.
- [ ] **Threat-model safe-tier reads.** Classify returned data by sensitivity and prevent an
      untrusted workflow from combining permitted reads with an outbound channel that leaks
      private data.
- [ ] **Build adversarial fixtures** for hostile email, webpages, SMS, calendar content,
      integration payloads, workspace Markdown, and tool output. Each fixture should attempt
      gated execution, policy modification, secret discovery, cross-recipient sending, and
      budget exhaustion.
- [ ] **Run those fixtures through the real Dispatcher/command path**, not prompt-only unit
      tests. Assert **both** non-execution and the expected Security record.
- [ ] **Bind provenance to claimed Dispatch items.** Prefer one provenance class per run; if
      batching remains, prove that one untrusted item cannot borrow a trusted item's
      capabilities.
- [ ] **Add per-run command, tool, token, time, and outbound-attempt budgets.** Budget
      exhaustion must stop the run and produce a visible event.
- [ ] **Pin supported harness versions** or add startup probes for their critical confinement
      behavior. External warning text **must not be the only thing** preventing an OpenCode
      fail-open.
- [ ] **Add live signed-in browser tests** for the payment gate and the four missing `nosniff`
      headers, closing launch items **G-34** and **G-35**.

### Exit criteria

- **Every command/caller combination** is mechanically accounted for.
- **Hostile content from every supported ingress** fails to gain a gated capability or leak
  protected data.
- **A harness behavior change fails closed** with an actionable error.
- **Real-browser checkout and media-header tests** run automatically at an appropriate CI
  cadence.

---

## Phase 3 — Give local data a safe upgrade path

> **Priority: P1.** Complete **before the first cohort receives an update**.

### Work

- [ ] **Introduce a workspace seed manifest** containing asset ID, schema version,
      shipped-content hash, installed-content hash, and ownership class.
- [ ] **Divide seeded files into three classes:** code-enforced security baselines,
      upgradeable untouched defaults, and operator-owned documents.
- [ ] **Move non-negotiable trust restrictions into code.** `policy.md` may tighten the
      baseline but **must not be the only delivery mechanism** for a security correction.
- [ ] **Upgrade an untouched default automatically** when its installed hash matches a known
      shipped version.
- [ ] **For an operator-edited file, preserve the file** and write a reviewed `.new` or
      structured merge proposal. Show the pending upgrade in Settings rather than silently
      ignoring it.
- [ ] **Version command catalogs, skills, jobs, trusted-sender templates, agent settings, and
      MCP configuration** through the same mechanism rather than bespoke `ensure/0` behavior.
- [ ] **Create fixture databases and workspaces for each released version.** Test database
      migrations, seed upgrades, rollback-safe failures, moved workspaces, corrupt manifests,
      full disks, and process death during writes.
- [ ] **Exercise SQLite contention** with Dispatcher, chat, and Sentinel writers active
      together. Convert unexplained `database busy` outcomes into explicit retry or
      failure behavior.

### Exit criteria

- An **untouched** old install receives safer defaults automatically.
- An **edited** old install keeps its work and receives a **visible upgrade proposal**.
- A failed upgrade is **recoverable** and never leaves policy, catalog, and code on an
  unreported mixed version.
- Release-update tests use **real historical fixtures**, not newly constructed current
  schemas.

---

## Phase 4 — Reduce architectural change amplification

> **Priority: P1.** Begin **after the security contracts stabilize** so they are not
> reimplemented twice.

### Work

- [ ] **Turn `StatusLive` into a page coordinator.** Extract chat, communications,
      notifications, studio, notes, calendar, weather, and Explore state into domain-owned
      modules or isolated LiveViews/components with explicit inputs and events.
- [ ] **Split `BusterClaw.Agent.Chat`** into a documented state machine, delivery persistence,
      queueing/steering, transcript projection, and backend transport adapters.
- [ ] **Inventory native-shell responsibilities** and define one cross-language contract for
      Phoenix/Tauri commands. Generate handler/capability declarations from a shared manifest
      where possible; **keep the ACL lockstep test as defense in depth**.
- [ ] **Add a hotspot check that fails on growth** in agreed files until each extraction lands.
      The goal is not an arbitrary line limit; it is **preventing known responsibility
      clusters from silently regrowing**.
- [ ] **Burn down the Dialyzer baseline by risk order:** audit/policy → command dispatch →
      Dispatcher/orchestration → browser control → filesystem operations → UI. New
      suppressions require a **written justification next to the exact finding**.
- [ ] **Replace ignored returns in durability and security paths** with explicit success,
      retry, degradation, or operator-visible failure handling.

### Exit criteria

- Each top-level LiveView owns **navigation and composition**, not several business domains.
- Agent chat has **explicit, testable state transitions** independent of HEEx rendering.
  *(The trading workflow that shared this criterion was deleted 08-08; `StatusLive` and
  `Agent.Chat` remain — the two largest extractions, and now the only ones.)*
- **No known security or durability path relies on an ignored return** without a documented
  best-effort contract.
- **The largest files cannot regrow unnoticed in CI.**

---

## Phase 5 — Contain or rebuild Trading — **RESOLVED BY DELETION 2026-08-08**

> **The decision gate demanded one of two honest products: read-only research, or
> controlled execution with an application-owned broker boundary. It said "do not
> keep a halfway state indefinitely."**
>
> The operator took a third option the phase did not offer and **deleted the
> surface** (`293f47f`), together with Portfolio, MarketData, Watchlist and Chart
> Build — which could not survive it, having no writer or no UI of their own.

Every exit criterion is met, though not in the way the phase imagined:

- **No model-generated number silently becomes authoritative financial history** —
  there is no financial history.
- **No order reaches a broker through free-form model prose** — no order reaches a
  broker.

**What is worth carrying to the next money-shaped surface,** because it was learned
the expensive way and is not specific to Robinhood:

1. **Transcription is the risk, not judgement.** The one measured failure on that
   surface was *silent fabrication* — a cheap model invented a broker answer rather
   than erroring. A read that fabricates half the time is worse than a read that
   costs more.
2. **A display convention used as a key will collide.** Last-four was the account
   identity in 42 places.
3. **Irreversibility asymmetry decides the design.** The ledger was durable because
   the broker published no history; the bar cache was disposable because a lost bar
   is one tool call away. *Which half a datum falls in should decide its schema
   before anything else does.*
4. **A checkbox in an archived roadmap is a claim about the past.** The archived
   trading review recorded OAuth, PKCE and HMAC account keys as done. None of it
   was ever in the tree.

**Do not treat this phase as reopenable.** If a financial surface returns, it starts
from requirements, not from this document.

## Phase 6 — Make the packaged application the tested product

> **Priority: P1.** This phase **consumes** the detailed Apple work in `LAUNCH_ROADMAP.md`
> rather than duplicating it.

### Work

- [ ] **Build from a clean clone** with cold dependency and asset setup. Assert the Mix
      release, ERTS, migrations, static assets, command launcher, and native resources are
      present.
- [ ] **Produce native Apple Silicon and Intel artifacts on their matching runners.** Sign
      every Mach-O, notarize, staple, and verify the **quarantined** downloads.
- [ ] **Run packaged smokes against each artifact:** boot, health, auth tiers, CLI bridge,
      terminal PTY, hidden webview render, browser ACL, workspace creation, clean shutdown.
- [ ] **Exercise first launch** with no prior data, no agent CLI, no Homebrew, no network, a
      non-admin account, denied permissions, two simultaneous launches, and a moved workspace.
- [ ] **Decide and verify the supported macOS floor**, then **generate** README/download-page
      compatibility text from the release metadata.
- [ ] **Implement and test the updater** with per-architecture metadata, signed update
      payloads, safe BEAM shutdown, workspace preservation, database migration, rollback
      behavior, and lost-key recovery documentation.
- [ ] **Prove the bundle contains no** development database, `.env`, source tree, PLT, test
      fixture, plaintext token, or private signing material.

### Exit criteria

- **A signed artifact downloaded from the web opens offline on clean supported hardware.**
- **Both architectures** pass the same packaged acceptance suite.
- **A real prior version updates** without losing the database, workspace, keychain
  credentials, or audit history.
- **Source-level green checks are never used as evidence that the distributable works.**

---

## Phase 7 — Make failures supportable and public release measurable

> **Priority: P2** for a private beta; **mandatory** for unrestricted public distribution.

### Work

- [ ] **Add a user-facing error center** for crashed agent runs, audit failures, unavailable
      integrations, migration failures, and degraded native features. **Every error needs an
      action, not just a stack trace.**
- [ ] **Add consent-gated, default-off crash reporting** and minimal product telemetry.
      Document collected fields, retention, deletion, and the fact that **audit content and
      workspace documents are excluded**.
- [ ] **Build a one-command diagnostic bundle** containing versions, effective feature flags,
      redacted configuration, migration state, recent structured logs, native capability
      status, and **no secrets**.
- [ ] **Normalize test logging** so expected crashes are explicitly captured and **unexpected**
      GenServer, Ecto ownership, or connection errors **fail the responsible test**.
- [ ] **Add soak coverage** for long-lived LiveViews, agent subprocess cleanup, SQLite writers,
      browser tabs, audio, shaders, and sleep/wake behavior.
- [ ] **Measure** cold start, idle CPU, idle battery impact, memory after eight hours,
      10,000-row Security rendering, large Dispatch queues, and shader fallback behavior.
- [ ] **Complete accessibility testing:** keyboard navigation, VoiceOver, contrast,
      reduced-motion, non-color status, locale, and non-US date formats.
- [ ] **Publish** the download page, privacy policy, terms, uninstall instructions, support
      path, agent-subscription requirement, and exact platform floor **before opening public
      downloads**.

### Exit criteria

- A user can **identify, export, and act on a failure** without reading BEAM or Rust stderr.
- **Expected test failures are quiet** and **unexpected runtime errors cannot hide inside a
  green run**.
- Public distribution has an **updater, support bundle, privacy terms, compatibility
  statement, and consent model**.
- **Performance and accessibility claims are backed by recorded measurements on packaged
  builds.**

---

## Milestones

| Milestone | Required phases | Allowed audience |
|---|---|---|
| **M0 — Honest internal build** | Phase 0 | Developer only |
| **M1 — Controlled private beta** | Phases 0–3 plus G-34/G-35 | Named technical collaborators with direct support |
| **M2 — Focused release candidate** | Phases 0–6 | Named external testers on supported Macs |
| **M3 — Public download** | Phases 0–7 and the complete `LAUNCH_ROADMAP.md` public gate | Unrestricted users |

## Finding-to-phase map

| Review finding | Primary response |
|---|---|
| Product has no single center | **Phase 0** |
| Unfinished surfaces look production-ready | **Phases 0 and 5** |
| Pending approvals are an in-memory stub | **Phase 1.1** |
| Audit claims exceed best-effort persistence | **Phase 1.2** |
| Permission bypass and kill switch are hidden | **Phase 1.3** |
| Command classification and prompt injection are under-tested | **Phase 2** |
| Seeded defaults never upgrade | **Phase 3** |
| Giant LiveViews and ignored returns amplify risk | **Phase 4** |
| Models remain in the financial data and order paths | **Phase 5** |
| Source tests outrun artifact evidence | **Phase 6** |
| Green tests contain operationally alarming noise | **Phase 7** |
| Public failures are invisible and unsupported | **Phase 7** |

## Completion gate for every phase

**Before a phase is marked complete:**

- [ ] Its implementation and tests are merged **without adding a new top-level feature**.
- [ ] `mix precommit`, JavaScript tests, Dialyzer, Sobelow, dependency audit, and docs-drift
      checks **pass**.
- [ ] Relevant **real-browser and packaged smokes** pass at the boundary that can actually
      fail.
- [ ] User-facing documentation describes the **resulting** behavior, not the intended
      behavior.
- [ ] The phase's **exit criteria have evidence attached** in this document or the canonical
      launch item.
- [ ] Any **deferred risk names an owner**, affected audience, containment, and explicit
      condition for revisiting it.

---

> **The roadmap succeeds when BusterClaw can remove this remediation section without weakening
> the truth of the review:** one understandable product, enforceable trust boundaries,
> upgradeable local state, contained experimental surfaces, and release evidence taken from
> the artifact users actually run.
