# Model versatility — choosing the model, and saying so

**Scoped 08-03-26 · Status: SCOPED, nothing built.**

Buster Claw runs every agent through the operator's own `claude` CLI, and today
it never tells the CLI which model to use. Every run — the homepage chat, a
trading read, an order submission, the on-duty dispatcher, a swarm — inherits
whatever that CLI happens to be configured for. This roadmap adds an in-app
model setting the app actually passes, a small number of per-surface overrides,
and the Explore tutorial that explains it.

**Scope decided by the operator 08-03:** *pick + explain* (a real setting, plus
the tutorial), with a *global default plus per-surface overrides*. Not a
docs-only pass, and not a full per-surface matrix where every surface must be
chosen individually.

---

## The lay of the land (read before building)

**The plumbing is already there and has never been used.** `AgentRunner`
accepts `:model` and turns it into `--model` (`agent_runner.ex:180-185`).
**Nothing in `lib/` passes it** — zero callers. This is the third instance this
week of a mechanism that exists, is documented, and cannot be reached (the other
two: `Egress.prepare`'s `:overrides`, and `secret_resolver`).

**One opt covers both entry points.** `run/2` (blocking) and `open/2` (the
chat's streaming path) both go through `build_args/3 → default_args/3 →
model_args/1`. There is no second place to wire.

**`--model` is claude-only by construction.** `default_args(:codex, ...)`
ignores `:model` entirely. That is correct and should stay: the app already
treats codex as a degraded path (it chokes on the MCP flags), and a model
selector that silently does nothing on codex would be worse than one that
visibly does not apply.

**The setting belongs in `Settings`, not a workspace file.** Same reasoning as
the egress overrides on 08-03: a seeded workspace file could never be improved
on an install that already had one (`LAUNCH_ROADMAP` **V.8**). Shipped defaults
live in code; the operator's choice lives in `Settings`.

### The measurement this whole roadmap has to respect

`trading.ex:883` records what happened the last time a surface here ran cheap:

> *"NOT haiku. It was chosen when these reads were cheap and their failure mode
> was assumed to be an error; measured on 07-28 it invoked the broker tool in
> only 1 of 2 runs, and on the miss it invented the answer rather than reporting
> a problem. A read that silently fabricates half the time is worse than a read
> that costs more."*

**A cheaper model on a money surface did not fail — it fabricated.** That is the
argument for per-surface overrides existing at all, and it is why the trading
and order surfaces get a floor rather than a preference.

### The surfaces that spawn runs

| Surface | Call site | Character |
|---|---|---|
| Chat (home + Trading tabs) | `Chat` → `AgentRunner.open/2` | Interactive, operator watching |
| Trading reads | `trading.ex:894` | **Money in, fabrication measured** |
| Order submission | `trading_order.ex:253` | **Money out, irreversible** |
| Dispatcher (on-duty) | `dispatcher.ex:74` | Unattended, volume, cost-sensitive |
| Swarm planner | `swarm/coordinator.ex:49` | One serial run that decides the shape |
| Swarm sub-runs | `swarm.ex:60` | Fan-out, the volume in a swarm |

Note the swarm split: the planner is one run whose quality determines everything
downstream, while the sub-runs are the volume. That is the clearest genuine
cheap/capable divide in the app, and it argues against a single global knob.

---

# Phase 0 — Decide (a conversation, not a build)

- [ ] **The model list.** Which models the picker offers, and whether it is a
      fixed list or free text. Current set: `claude-opus-5`, `claude-sonnet-5`,
      `claude-haiku-4-5`, plus `claude-fable-5` at the top end. **Recommend a
      fixed list plus a free-text escape hatch** — a fixed list goes stale (this
      set has changed repeatedly), and the CLI accepts aliases we do not control.
- [ ] **What "unset" means.** Recommend: unset = **pass no `--model` at all**,
      inheriting the CLI's own default. That keeps today's behavior as the
      default and makes the feature purely additive. The alternative — defaulting
      to a named model — silently changes what every existing install does on
      upgrade.
- [ ] **Which surfaces get a floor rather than a preference.** Recommend
      **trading reads and order submission** are floored: an operator lowering
      the global default must not be able to reach them. This is the 07-28
      finding expressed as a constraint rather than a comment.
- [ ] **Whether a floor is overridable at all.** Recommend **yes, but
      explicitly** — a per-surface override can raise or lower it, but lowering
      the money surfaces requires setting *that surface*, never the global.

# Phase 1 — The setting and the wiring

- [ ] `BusterClaw.ModelPolicy` (a leaf): `for_surface/1` returning the model
      string or `nil`, shipped defaults in code, operator entries in `Settings`.
      **Leaf, not a function on an existing module** — every surface calls it,
      and this week's `Trading → ChartBuilder → Portfolio` cycle came from
      exactly this kind of convenience placement.
- [ ] Pass `model:` at the six call sites above. `nil` must mean *omit the flag*,
      not `--model ""`.
- [ ] **A test per money surface** asserting the floor holds when the global
      default is set below it. This is the regression guard for the 07-28
      finding; without it the floor is a comment.
- [ ] A test that an unset policy produces **no `--model` argument** — the
      "purely additive" promise, in the suite.

# Phase 2 — The surface

- [ ] Where the setting lives in the UI. **Recommend Settings**, next to the
      other agent configuration, not a new tab.
- [ ] Show what is *in force* per surface, not just what the operator typed —
      the same lesson as `browser_egress_level`'s `in_force` vs `operator_set`.
      An operator who set a global default and is silently overridden on trading
      should be able to see that.
- [ ] `model_policy` command surface, mirroring `browser_egress_level`: no args
      lists what is in force, `surface` + `model` sets one. Tier `:restricted`.

# Phase 3 — The explanation (the original ask)

- [ ] A **Models** tutorial in Explore. The tab system makes this one
      `@features` entry plus a panel function (`explore_panel.ex` moduledoc).
- [ ] It has to teach the *shape*, not just the setting: Buster Claw drives your
      own `claude` CLI, so the model is yours and the cost is yours; the app
      names a model per surface; and unset means the CLI decides.
- [ ] **Say the quiet part.** The tutorial should carry the 07-28 finding in
      plain language — a cheaper model on the trading surface fabricated an
      answer rather than erroring, which is why the money surfaces have a floor.
      An operator who understands *why* the floor exists will not fight it.
- [ ] Cross-check: `introduction.ex` currently says nothing about models. If the
      agent should know which model it is (it usually should not), that is a
      separate decision — do not add it by reflex.

# Phase 4 — Optional, re-justify when reached

- [ ] Per-conversation model choice on the Trading tab strip, the way `kind`
      works today. Only if real use shows people wanting it per-chat rather than
      per-surface.
- [ ] Cost reporting per surface. Attractive, and a much bigger build than it
      sounds — the CLI does not report spend back to us.

---

## Order

**Phase 0 first, and it is short.** The "what does unset mean" question is the
one that matters: get it wrong and the feature changes behavior for every
existing install on upgrade.

Then **Phase 1**, because the setting is worthless until something reads it, and
**the floor tests are part of Phase 1, not a follow-up** — an unenforced floor on
a money surface is the exact shape of the thing this roadmap exists to prevent.

**Phase 3 is the original ask** and can be written as soon as Phase 1 lands —
the tutorial only needs the behavior to be true, not the Settings UI to be
pretty. If Phase 2 slips, Phase 3 still ships something honest.

**The failure mode to watch for:** this feature's whole purpose is letting people
spend less, and the one measured consequence of spending less here was a
fabricated financial answer. Every phase should be asked the same question — can
an operator lower cost in a way that silently reaches a money surface?
