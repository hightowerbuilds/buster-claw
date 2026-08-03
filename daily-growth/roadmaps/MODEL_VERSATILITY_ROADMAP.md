# Model versatility — choosing the model, and saying so

**Scoped 08-03-26 · Status: Phases 0–3 SHIPPED 08-03. Phase 4 deferred.**
**Successor scope: `AGENT_BACKEND_ROADMAP.md`** — this roadmap chose the *model*;
that one chooses the *runner the model runs in*, and it corrects one claim made
here (see the note on codex under Phase 0).

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

**`--model` reaches claude only.** `default_args(:codex, ...)` ignores `:model`
entirely, so a model set here does nothing on a codex run.

> **Corrected 08-03, after this shipped.** The original wording said this was
> "claude-only *by construction*" — that the flag had nowhere to go on codex.
> Wrong about the reason: `codex-cli` 0.146.0 takes `-m, --model` and always has;
> we simply never passed it. The behaviour described above is still what the code
> does, but it is an *omission*, not a constraint. `AGENT_BACKEND_ROADMAP.md`
> measures all three CLIs from `--help` rather than from memory, and fixing this
> is its Phase 1.

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

# Phase 0 — Decide (a conversation, not a build) — **LOCKED 08-03**

All four decided as recommended, and all four are now enforced by
`model_policy_test.exs` rather than by this document.

- [x] **The model list.** A fixed list (`claude-fable-5`, `claude-opus-5`,
      `claude-sonnet-5`, `claude-haiku-4-5`) **plus a free-text escape hatch** —
      `valid_model?/1` accepts any non-blank string. The picker's list is a
      convenience, not a gate: this set has changed repeatedly and the CLI
      accepts aliases we do not control.
- [x] **"Unset" = pass no `--model` at all.** `for_surface/1` returns `nil` and
      callers omit the flag; `AgentRunner.model_args/1` already produces `[]` for
      a non-binary. The feature is purely additive — an install that upgrades
      into it behaves exactly as it did the day before.
- [x] **Floored surfaces: trading reads and order submission**, at
      `claude-sonnet-5`. A lowered *global* default cannot reach them.
- [x] **A floor is overridable, but only by naming that surface.** The
      cost-saving gesture and the money-touching consequence are deliberately not
      the same gesture.

Two implementation notes worth carrying:

- **The rank map is not the picker list.** Floors are evaluated on a capability
  rank, and an *unranked* model — a new release, an alias, an operator's own
  string — passes a floor untouched. Refusing to run a string we simply do not
  recognise would break the escape hatch the whole picker depends on. The cost is
  that a floor is unenforced for models we have never heard of; that is the right
  trade, but it means **adding a cheap model to the picker without ranking it
  silently exempts it from the floor.** `model_policy_test.exs` asserts every
  floor model is ranked; it cannot assert that about a model nobody added yet.
- **`ModelPolicy` is a leaf on purpose.** Nothing in it calls a surface; every
  surface calls in. Hanging it off `Trading` or `AgentRunner` for convenience is
  exactly the placement that produced the `Trading → ChartBuilder → Portfolio`
  cycle earlier the same day.

# Phase 1 — The setting and the wiring

- [x] `BusterClaw.ModelPolicy` (a leaf): `for_surface/1` returning the model
      string or `nil`, shipped defaults in code, operator entries in `Settings`.
      **Leaf, not a function on an existing module** — every surface calls it,
      and this week's `Trading → ChartBuilder → Portfolio` cycle came from
      exactly this kind of convenience placement.
      **Built 08-03**, with `in_force/0` (resolved model + `source` +
      `floor` per surface) for the UI, and 20 tests.
- [x] Pass `model:` at the six call sites above. `nil` must mean *omit the flag*,
      not `--model ""`. **Done 08-03** — `chat.ex:668`, `trading.ex:894`,
      `trading_order.ex:254`, `dispatcher.ex:226`, `swarm/coordinator.ex:60`,
      `swarm.ex:71`. The four `Keyword.put_new` sites leave an explicit caller
      opt in charge; the two money surfaces resolve unconditionally.
- [x] **A test per money surface** asserting the floor holds when the global
      default is set below it. This is the regression guard for the 07-28
      finding; without it the floor is a comment. **Done** —
      `model_policy_wiring_test.exs`, which asserts on the opts the *production*
      code hands its runner, never on `for_surface/1`. Re-asserting the
      resolution here would pass whether or not the wiring existed.
      `trading.ex` grew a `:trading_agent_runner` seam for this, because the
      per-read `:trading_*_fetcher` seams replace the function wholesale and so
      can never show a test what opts it built.
- [x] A test that an unset policy produces **no `--model` argument** — the
      "purely additive" promise, in the suite. **Done**, and at two depths: the
      surfaces pass `nil`, and a real `AgentRunner.run/2` against a stand-in CLI
      proves `--model` is absent from the argv rather than present-and-empty.

# Phase 2 — The surface — **DONE 08-03**

- [x] Where the setting lives in the UI. **Settings**, next to the other agent
      configuration, not a new tab.
- [x] Show what is *in force* per surface, not just what the operator typed —
      the same lesson as `browser_egress_level`'s `in_force` vs `operator_set`.
      `ModelPolicy.in_force/0` returns the resolved model plus the `source` that
      decided it (`:surface | :floor | :default | :cli`) and the surface's floor,
      so an operator who set a global default and is overridden on trading can
      see *which* rule did it.
- [x] `model_policy` command surface, mirroring `browser_egress_level`: no args
      lists what is in force, `surface` + `model` sets one, `clear` unsets.
      Tier `:restricted`, **and `gated: true`** — `gated` also keeps out an
      unattended run working untrusted content, which is exactly the caller an
      injected page would use to downgrade the money path quietly (T5).
      The command's `surface` enum is read from `ModelPolicy.surface_keys/0`
      rather than retyped, so it cannot drift from the policy.

# Phase 3 — The explanation (the original ask) — **DONE 08-03**

- [x] A **Models** tutorial in Explore — one `@features` entry plus
      `models_panel/1` (`explore_panel.ex:401-...`), the 5th built tutorial.
- [x] It teaches the *shape*, not just the setting: the app holds no Claude API
      key, so the model is yours and so is the bill; the surface list is asked
      first-match-wins; unset means the flag is omitted and the CLI decides.
- [x] **Say the quiet part.** The 07-28 finding is on the page in plain language
      — "it invented the answer" — as the reason the money surfaces have a floor,
      and it says the floor is escapable only by naming that surface.
- [x] The surface rows and floor models are **rendered from `ModelPolicy`**, not
      retyped, and `status_live_test.exs` walks every `surface_keys/0` entry and
      every `floors/0` value through the rendered HTML. A tutorial that describes
      a surface set the policy no longer has is the failure mode that test exists
      to prevent.
- [x] Cross-check: `introduction.ex` says nothing about models — **checked and
      deliberately left alone.** The agent knowing which model it is buys
      nothing here, and adding it would be reflex rather than a decision.

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
