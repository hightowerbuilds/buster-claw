# Agent backends — Codex and OpenCode as first-class runners

**Scoped 08-03-26 · Status: ACTIVE — Phase 0 probed, Phase 1 SHIPPED.**
**Successor scope to `MODEL_VERSATILITY_ROADMAP.md`** — that roadmap chose the
*model*; this one chooses the *runner the model runs in*, and the two are not
separable. A model ID means nothing without a backend to interpret it.

Buster Claw has always had two backends in the code (`:claude` and `:codex`) and
has only ever really had one. `detect/0` falls back to codex on PATH order, and
`default_args(:codex, prompt, _opts)` is `["exec", prompt]` — no model, no
permission mode, no streaming, no MCP. This roadmap makes codex and OpenCode real
runners and lets the operator pick.

> **Progress, 08-03.** **Phase 0's probes were run** — every ⚠ and every event
> schema below is a measurement, not a recollection. **Phase 1 shipped**:
> `BusterClaw.AgentBackend` is the leaf table, `AgentRunner.default_args/3` is a
> dispatch through it, codex finally receives `--model`, `-s` and `--json`, and
> opencode joined `detect/0` **last in the order**, so no machine that already
> resolved to claude or codex resolves anywhere new.
>
> One thing arrived beyond the phase list, and it is the important one: the
> opencode fail-open is now **enforced, not merely documented**. `run/2` returns
> `{:error, {:unconfined, result}}` when the CLI drops the `--agent` we gave it,
> because a safety control nothing calls is a comment. The streaming path
> (`open/2`) cannot do this for its caller and says so in its own docs — that is
> a real remaining edge, not a covered one.
>
> **Next:** Phase 2, `ModelPolicy` keyed on `{backend, surface}`. Nothing in
> Phase 1 is user-visible yet — the operator still cannot *choose* a backend, and
> until Phase 2 lands a stored model string is claude's namespace by assumption.

**Decided by the operator 08-03:**
- **Backend choice: global default plus per-surface override**, mirroring
  `ModelPolicy` exactly, so backend and model are chosen with one mental model
  rather than two. `ModelPolicy` becomes `{backend, model}` per surface.
- **The money surfaces may run any backend, with a loud warning.** Not
  Claude-only. See *The floor problem* below for what that costs and what the
  build must therefore do; the operator made this call with that cost stated.

---

## Measured, not recalled (08-03, this machine)

Every row below came from running `--help` on the installed binary. The previous
roadmap asserted "`--model` is claude-only **by construction**" and was wrong
about the reason — codex has taken `-m` all along; we simply never passed it.
That is the fifth time this week a written claim and the tool disagreed, and it
is why this table exists before any code does.

| | `claude` 2.1.220 | `codex-cli` 0.146.0 | `opencode` 1.18.3 |
|---|---|---|---|
| Non-interactive | `-p <prompt>` | `exec <prompt>` | `run <message>` |
| **Model** | `--model <id>` | `-m, --model <MODEL>` | `-m provider/model` |
| Streaming JSON | `--output-format stream-json --verbose` | `--json` (JSONL) | `--format json` |
| Final message only | — | `-o, --output-last-message <FILE>` | — |
| Permissions | `--permission-mode` | `-s read-only\|workspace-write\|danger-full-access` | `--auto` (binary) |
| Tool scoping | `--allowedTools` / `--disallowedTools` | via `-c` TOML override (**unprobed**) | `--agent <name>` + a generated agent file (`--permissions` allowlist) |
| MCP | `--mcp-config <file>` `--strict-mcp-config` | `codex mcp add` (**global**, persistent) | `opencode mcp` (**global**) |
| Working dir | port `cwd` | `-C, --cd <DIR>` | `--dir <DIR>` |
| Resume | `--resume <id>` | `exec resume --last` / `<id>` | `-c` / `-s <id>` |
| Structured output | — | `--output-schema <FILE>` | — |

### Three asymmetries that decide the build

**1. Model IDs are not one namespace, and only one backend will enumerate them.**
OpenCode wants `provider/model`; claude wants a bare ID; codex wants its own. A
single stored string is *wrong for two of three backends*. `ModelPolicy` stores
one bare string today — this is the change that forces it to become
backend-keyed rather than a nicety.

Enumeration is uneven, and this decides how the picker is built:

| Backend | Enumerate? | How the picker is populated |
|---|---|---|
| `opencode` | **Yes** — `opencode models` | Ask the CLI at runtime |
| `codex` | No — there is no `codex models` | Shipped list + free text |
| `claude` | No — `--model` documents aliases, nothing lists them | Shipped list + free text |

**`opencode models` returned 23 entries on this machine** — `opencode-go/glm-5.1`,
`glm-5.2`, `kimi-k2.6`, `kimi-k2.7-code`, `kimi-k3`, `qwen3.8-max`,
`minimax-m3`, `grok-4.5`, and a set of `-free` tiers. That list reflects **which
providers this operator has authenticated**, so it is per-machine, not a
constant. It must be read live and cached, never shipped — and it is the single
strongest argument for keeping the free-text escape hatch on every backend, since
two of the three cannot be enumerated at all.

Incidental find worth a look later: claude has `--fallback-model`, "automatic
fallback when the default model is" unavailable. Out of scope here, but it is a
real answer to a capacity failure the app currently handles as an error.

**2. Confinement is expressible on the command line for exactly two of three.**
Claude's trading confinement is three-part and every part is load-bearing
(`trading.ex:290-308` records the probe that proved it): `--mcp-config` scopes
which servers exist, `--disallowedTools` refuses the built-ins, `--allowedTools`
pre-approves the reads.
- **Codex** has a genuine analogue for the *read* surface in `-s read-only` — an
  OS-level sandbox, arguably stronger than a flag allowlist. Its MCP story is
  `codex mcp add`, which is **global and persistent**, not a per-run file. A
  per-run equivalent via `-c mcp_servers.…` TOML override is *plausible and
  unprobed* — Phase 0 must probe it, because if it does not work, a codex
  trading run cannot be scoped to Robinhood alone.
- **OpenCode** expresses confinement in a **file**, not on the command line, and
  that file is a shape this codebase already ships. `opencode agent create`
  takes `--permissions/--tools` — a comma-separated allowlist over
  `bash, read, edit, glob, grep, webfetch, task, todowrite, websearch, lsp,
  skill` — and `--path`, the directory the agent file is written to. `opencode
  agent list` shows the resulting permission records are `{permission, pattern,
  action}` triples with `allow` / `ask` / `deny` and glob patterns. `--auto`
  ("auto-approve permissions that are not explicitly denied") is then the *run*
  knob, and it is only as dangerous as the agent file is loose.

  So OpenCode's model is **seed a definition, then name it with `--agent`** —
  which is exactly what `Trading.ensure_mcp_config/0` already does for Claude
  (`<workspace>/mcp/robinhood.json`, never overwritten). Not a foreign pattern.

  Two real caveats remain, and they are narrower than "no confinement":
  1. **Granularity is coarser.** Claude's trading confinement names individual
     MCP tools (`@read_tools`); OpenCode's documented allowlist is 11 broad tool
     categories. Whether its `pattern` field reaches MCP-tool granularity is
     **unprobed** and is what decides if an OpenCode trading run can be limited
     to Robinhood reads specifically rather than "webfetch off, read on".
  2. **A seeded file cannot be tightened later** — `LAUNCH_ROADMAP` **V.8**, the
     open `maybe_write` problem: shipped defaults can never be corrected on an
     install that already has the file. Seeding a *permission* file makes that
     latent issue load-bearing, because a too-loose agent definition shipped once
     is permanent for that install. This is an argument for generating the agent
     file per run rather than seeding it once.

**3. The stream parsers are Claude-shaped.** `Agent.StreamEvent` is documented as
"the shared parser for Claude's `--output-format stream-json` output" and is what
`trading.ex`'s `verified_result/1` uses to confirm the broker tool was *actually
invoked* — the anti-fabrication check. Codex `--json` and OpenCode
`--format json` emit different event schemas. `StreamEvent` is the right seam,
but it needs a parser per backend, not a flag.

One piece of good news in that: if a backend's output cannot be parsed,
`verified_result/1` **errors** rather than passing an unverified answer through.
The failure degrades to a loud error, not to a silent fabrication.

### The gotcha that would waste an afternoon

**Codex refuses to run outside a git repository.** It needs
`--skip-git-repo-check`, and the shipped workspace root
(`~/Desktop/BusterClawCLI`) is not a repo. Every codex run from the workspace
fails without that flag. Nothing in the CLI's error path points at the fix.

---

## The floor problem

This is the part the operator decided against the recommendation, with the cost
stated. Recording it here so it is a known, chosen trade rather than a surprise.

`ModelPolicy`'s money-surface floor is evaluated on `@capability_rank`, which
ranks **only Claude models**. Unranked models pass a floor untouched — deliberate,
because refusing a string we do not recognise would break the free-text escape
hatch the whole picker depends on.

**Therefore: switching a money surface to codex or opencode makes every model on
it floor-exempt.** The protection does not warn and does not degrade — it simply
stops applying. That is precisely the question `MODEL_VERSATILITY_ROADMAP` says to
ask of every phase ("can an operator lower cost in a way that silently reaches a
money surface?"), and backends are the first time the answer is yes.

Because the operator chose to allow it, the warning has to be **structural, not
cosmetic**, or this ships the failure mode the previous roadmap exists to prevent:

- [ ] A non-Claude backend on `:trading_read` or `:order_submit` is a **distinct
      persisted state**, not just a rendering condition — so the warning cannot be
      lost by a refactor of the settings template.
- [ ] The Sentinel audit trail records the backend on every money-surface run.
      Today it records the run; it must record *what ran it*.
- [ ] Order submission carries the warning at the **confirmation** step, where the
      decision is actually made — not only in Settings, where it was made a week
      ago.
- [ ] A test asserts the warning state is reachable and correct. An unenforced
      warning is the same shape of thing as an unenforced floor.

**What must NOT happen:** a per-backend capability rank invented from guesswork so
the floor "still applies." The 07-28 fabrication measurement was made on Claude
models and says nothing about GPT-5.1-codex or anything OpenCode routes to. A
floor built on an unmeasured rank is worse than an absent one, because it reads as
protection. If a per-backend floor is wanted, **measure first** — Phase 4.

---

# Phase 0 — Probe before designing — **DONE 08-03**

Every item was a command run against the installed binaries, not a decision had.
Results below; the two marked ⚠ change the build.

## ⚠ OpenCode fails OPEN when a named agent is missing

```
$ opencode run --agent no_such_agent_xyz --dir <dir> "hi"
! agent "no_such_agent_xyz" not found. Falling back to default agent
… runs normally … exit=0
```

The fallback is the **`build` agent, whose permissions are
`{permission: "*", action: "allow", pattern: "*"}`** — allow everything. So a
missing, malformed, or wrongly-pathed agent file does not fail the run: it runs
it **unconfined and reports success**. The only signal is a human-readable line on
stderr, and the exit status is 0.

This is the exact "silently reaches a money surface" shape the model roadmap
exists to prevent, arriving by a route no floor would catch. **Therefore:**

- [x] **DONE (Phase 1).** An OpenCode run on a confined surface must **verify the
      agent was actually used**, not trust that `--agent` was passed.
      `AgentBackend.fallback_warning?/2` detects the line, and `AgentRunner.run/2`
      turns it into `{:error, {:unconfined, result}}` — a refusal, not a warning.
      The result rides along so a caller can still show what happened.
- [x] **DONE (Phase 1).** A test asserts that a run whose agent file is absent is
      **refused**, not completed — and a companion asserts the same words from
      claude are *not* a failure, so the check cannot become a false alarm on the
      backend every real run currently uses.
- [ ] **STILL OPEN: the streaming path cannot do this.** `AgentRunner.open/2`
      hands the caller the port, so nobody is reading the output on their behalf.
      It is documented there, which is not the same as handled. Whatever wires a
      confined surface to opencode must check `fallback_warning?/2` itself, and
      chat streams through `open/2`.

## ⚠ `codex -c` merges; it cannot scope MCP down

`-c 'mcp_servers.probe_srv.command="echo"'` **adds** a server for that invocation
(verified: `probe_srv` appears, and is absent from the baseline). But neither
`-c 'mcp_servers={}'` nor `-c 'mcp_servers={probe_srv={…}}'` **removes** the
operator's existing servers — `github` survived both. There is no `-c` equivalent
of Claude's `--strict-mcp-config`.

`codex exec --ignore-user-config` is the remaining candidate (it is an `exec`
flag; `codex mcp list` rejects it, which is why this is not yet settled). **Until
that is probed, a codex trading run cannot be proven scoped to Robinhood alone,
and the money-surface warning must say so specifically** rather than speaking
generally about floors.

## Confirmed as expected

- **Codex refuses a non-repo working root.** Without `--skip-git-repo-check`:
  `Not inside a trusted directory and --skip-git-repo-check was not specified.`
  With it, and with `-s read-only`, the run completes. The shipped workspace is
  not a repo, so this flag is mandatory, not optional.
- **Codex reads stdin unless it is closed.** A probe without `</dev/null` hung
  past three minutes. `AgentRunner` already redirects stdin from `/dev/null`
  (`agent_runner.ex:199-203`), so the app is already correct here — but any new
  spawn path must keep that, and the failure mode is a hang, not an error.
- **OpenCode reads a project-local `.opencode/agent/<name>.md` from `--dir`.**
  A hand-written frontmatter file (`mode:`, `tools: {write: false, …}`) was picked
  up and used. Confinement can therefore live in the workspace, per run — no need
  to touch the operator's global `~/.config/opencode/`.
- **OpenCode does not hang without `--auto`** — because its default agent allows
  everything, so nothing ever prompts. That is a reason to write an agent file,
  not a reason to relax.
- **Do not build on `opencode agent create`.** It calls an LLM to generate the
  config and failed here with `invalid temperature: only 1 is allowed for this
  model`. Hand-write the file.

## The event schemas (Phase 3's parsers)

**codex `exec --json`** — 4 event types, flat and clean:
```
{"type":"thread.started","thread_id":"…"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"OK"}}
{"type":"turn.completed","usage":{"input_tokens":…,"cached_input_tokens":…,"output_tokens":…}}
```

**opencode `run --format json`** — nested under `part`:
```
{"type":"step_start","sessionID":"…","part":{…,"type":"step-start"}}
{"type":"text","sessionID":"…","part":{"type":"text","text":"OK","time":{…}}}
{"type":"step_finish","part":{"reason":"stop","tokens":{"total":…,"input":…,"output":…,"cache":{…}},"cost":0}}
```

**Unplanned find, and it inverts a Phase 4 assumption.** The model roadmap says
"the CLI does not report spend back to us." True of claude — but **codex reports
token usage** on `turn.completed`, and **OpenCode reports an actual `cost`
figure** on `step_finish`. Per-backend cost reporting is therefore *cheaper* on
the two backends we are adding than on the one we have.

**All but one were run on 08-03; the answers are the sections above, not these
lines.** The one that is still open is the one that gates a codex money surface.

- [x] **Can codex scope MCP per-run?** **No.** `-c` merges and cannot remove; see
      *⚠ `codex -c` merges*.
- [ ] **Is `codex exec --ignore-user-config` the way to scope it?** Split out of
      the line above because it is the part that was *not* settled. Until it is
      probed, a codex trading run cannot be proven scoped to Robinhood alone, and
      Phase 3's money-surface warning has to say that specifically. **This is the
      highest-value remaining probe** — it decides whether codex can touch the
      money surfaces at all.
- [x] **What does `codex exec --json` actually emit?** Captured; the shapes are in
      *The event schemas* below, for both codex and opencode.
- [x] **How fine-grained is an OpenCode agent's permission list?** Hand-written
      file picked up and used. (`opencode agent create` is unusable as a build
      dependency — it calls an LLM and failed here.)
- [x] **Does OpenCode read a project-local `.opencode/` from `--dir`?** **Yes** —
      so confinement lives in the workspace, per run, and we never touch the
      operator's global config.
- [x] **Does headless OpenCode hang without `--auto`?** **No** — because its
      default agent allows everything, which is the fail-open above wearing
      another hat, not reassurance.
- [x] Confirm `--skip-git-repo-check` is sufficient for a codex run rooted in the
      non-repo workspace. **Yes, and it is mandatory** — it is unconditional in
      `AgentBackend.argv(:codex, …)` for that reason.

# Phase 1 — The backend abstraction — **SHIPPED 08-03**

- [x] A **leaf** `BusterClaw.AgentBackend` data module: per backend, the
      non-interactive argv shape, the model flag, the streaming flag, the
      permission/sandbox translation, and the model-ID namespace. It is a leaf.
- [x] `AgentRunner.default_args/3` becomes a dispatch through it rather than three
      hand-written clauses. `:argv` stays as the escape hatch.
- [x] Codex gets what it has always supported: `--model`, `--json`, `-s`, and
      `--skip-git-repo-check`. **`-C` was not needed** — `AgentRunner` sets the
      working directory through the Port's `:cd`, which applies to every backend
      and does not depend on each CLI having a flag for it.
- [x] OpenCode joins `detect/0`, **last**, and the order is now
      `AgentBackend.order/0` — one list that is both the fallback order and the
      registry, so a fourth backend cannot be added to one and forgotten in the
      other. A machine with claude or codex already installed resolves exactly as
      it did before.

**Two judgement calls made while building, both written into the code:**

- **`bypassPermissions` does NOT map to codex's `danger-full-access`.** The
  literal translation is tempting and wrong: on claude it waives the *prompt*
  while the tool allowlist still binds; on codex it waives the *sandbox*. Mapping
  them would silently escalate every existing headless run the moment its backend
  changed. It maps to `workspace-write`.
- **`dontAsk` on opencode emits nothing**, rather than `--auto`. opencode has no
  read-only analogue, and its only run-level knob approves everything — emitting
  it would turn our most confined mode into our least.

**Not yet true, and worth saying plainly:** none of this is reachable by an
operator. `detect/0` still picks by PATH order, so on any machine with claude
installed the new code paths are exercised only by tests. Phase 2 is what makes
the abstraction do anything.

# Phase 2 — `ModelPolicy` becomes `{backend, model}`

**The operator's stated shape (08-03): choose a harness, then choose a model
within it.** claude → opus; codex → its own; opencode → glm, kimi, qwen. The
model picker is meaningless until the harness is known, so the UI must present
them in that order and the storage must key on the pair.

- [ ] Per surface: a backend *and* a model, resolved together. **Store the model
      under `{backend, surface}`, not `surface`.** A stored `claude-opus-5` is
      meaningless once that surface is on OpenCode; keeping it keyed by surface
      alone means either showing a lie as in force or silently discarding a
      choice the operator would get back by switching the harness home again.
      Keying on the pair makes switching harness and switching back lossless.
- [ ] `in_force/0` grows a `backend` and reports **why** a model is not applicable
      when the backend changed underneath it.
- [ ] `known_models/0` becomes per backend, and **asks the CLI where the CLI will
      answer**: `opencode models` at runtime (cached — it shells out, so it must
      not sit in a render path), a shipped list for codex and claude, free text
      everywhere. Ship no OpenCode list at all; it is operator-specific.
- [ ] A backend the operator does not have installed must be visibly
      unavailable rather than selectable-and-broken. `detect/0` already knows;
      the UI does not ask it.
- [ ] The floor's Claude-only scope becomes **explicit in the data**, not implicit
      in an unranked lookup: a floor should know it does not apply to this backend
      and say so, rather than silently evaluating to no-op.

# Phase 3 — The surfaces

- [ ] Settings: backend picker beside the model picker, sharing the
      global-plus-override shape, with the money-surface warning from *The floor
      problem* above.
- [ ] `model_policy` command learns `backend`.
- [ ] Explore "Models" tutorial gains the backend story. **Correct the claim
      already written** at `explore_panel.ex:671` that codex "never took a model
      flag" — it does, and has.
- [ ] Per-backend stream parsers behind `Agent.StreamEvent`, so chat streams from
      any backend. This is the largest single item and it is what makes codex and
      OpenCode usable rather than merely launchable.

# Phase 4 — Only after measurement

- [ ] **Re-run the 07-28 fabrication probe per backend** before any per-backend
      floor exists. The probe is on record: run the trading read N times and count
      how often the broker tool was actually invoked versus the answer invented.
      Until that number exists for a backend, that backend has no floor and the
      UI must say so rather than implying one.
- [ ] Per-backend cost reporting. OpenCode has `opencode stats`; claude does not
      report spend back to us. Attractive, uneven, and much bigger than it sounds.

---

## Order

**Phase 0 first and it is cheap** — five commands. Two of them (codex per-run MCP
scoping, OpenCode's headless approval behavior) can invalidate a chunk of Phase 3,
and finding that out after building the parsers would be the expensive way.

**Phase 1 and 2 are one change in practice.** The abstraction without the policy
change gives a backend that runs with the wrong model IDs.

**Phase 3's parsers are the real cost.** Everything before them is flags; the
parser is the part that makes a non-Claude backend genuinely work. Budget for it
honestly rather than discovering it.

**The failure mode to watch for:** this roadmap's whole purpose is choice, and the
one measured consequence of choosing cheaply on these surfaces was a fabricated
financial answer. Ask every phase the same question the model roadmap asks — and
now that the money surfaces accept any backend, the answer must be "yes, and the
operator was told so at the moment of the decision," never "yes, silently."
