# 08-04-26

Six commits, one roadmap closed and archived. Yesterday's through-line was
written claims coming apart from code. Today's is the sequel and it is less
comfortable: **the suite was green through all of it, and an operator using the
app found two bugs it could never have caught.** Not because the tests were bad,
but because every one of them assumed the thing that had just stopped being true.

## Phase 4 was a much smaller build than its own roadmap said, because the roadmap was wrong

The line read: *"Cost reporting per surface. Attractive, and a much bigger build
than it sounds — the CLI does not report spend back to us."*

It does. Claude's `result` event carries `total_cost_usd`, `usage`, `num_turns`
and `modelUsage` — measured at `0.0802325` on a one-word prompt. Codex reports
token counts on `turn.completed`. OpenCode reports an actual dollar `cost` on
`step_finish`. **All three, all along.**

The tell had been sitting in the tree the whole time: `StreamEvent` has parsed
`total_cost_usd` since before any of this started. A parser that reads a field
the roadmap says does not exist is a contradiction nobody had looked at.

That claim had been copied into the agent-backend roadmap, the Explore tutorial,
the daily summary, `AgentBackend`'s own descriptor, and four messages to the
operator — all in one day, all by the same session that kept insisting on
measurement. **Seventh instance in two days of a written claim disagreeing with
the tool.** Corrected in all five places, with a test that refutes the old
wording so it cannot drift back.

What shipped instead of a big build: `StreamEvent.usage` normalizing
input/output/cache/cost across three measured shapes, and `run_usage/2` for the
blocking surfaces that hold the whole stream as one string. **Codex's cost stays
nil and must not be derived** — a price table this app does not own would make an
invented number look authoritative.

## The reversal: money surfaces are pinned to Claude

Yesterday the operator chose to allow any harness on trading reads and order
submission, with a loud warning, over the recommendation to keep them
Claude-only. That call was made with the cost stated and was reasonable on the
information available.

The information was incomplete. Both money surfaces hardcode Claude's
confinement vocabulary — `--allowedTools`, `--disallowedTools`,
`--strict-mcp-config` — and codex answers those with `error: unexpected argument
'--disallowedTools'`. Measured, not assumed.

So selecting codex there produced a run that **failed every time**. Not
cheap-and-unsafe: broken. And the warning shipped the day before said *"No floor
here… running unprotected"*, which implies it works and is merely unprotected.
The UI was misleading in the one place it most needed not to be.

Pinned instead, with `put_backend/2` refusing the choice and the Settings row
explaining why there is no picker rather than offering one that fails.
`unfloored_money_surfaces/0` is kept as a **live assertion** rather than deleted:
lift the pin without giving the floor a per-backend measurement and it starts
returning entries and its test fails. The pin and the floor have to move
together.

This also made Phase 4's other half moot in its original form. The per-backend
fabrication probe was the gate on a per-backend floor — but with no non-Claude
money run possible, there is nothing left to measure. The closeout says that
plainly instead of leaving a checkbox that reads as pending.

## Two bugs the operator found, and why the suite could not

**The global harness had no picker.** Every per-surface row got a harness
dropdown; the global default never did. So the only harness reachable from
Settings was whichever one PATH detection happened to find — the command could
set it, the UI could not. Everything read `claude` because nothing else was
reachable.

**Claude-only flags leaked into a codex argv.** Switching the harness made every
chat turn exit 2 with `unexpected argument '--append-system-prompt'`. The stream
flag and the resume flag had been made harness-aware; two more sitting in the
same list had not. `extra_cli_args` was the worse of the pair — the Trading chat
carries `--strict-mcp-config`/`--allowedTools`, so that conversation would have
failed every turn on any other harness.

**Neither was catchable, and the reason is specific:** until the fix, the suite
had **no test that ran a chat on a non-Claude harness at all.** Every chat test
implicitly assumed claude, so the entire class was invisible — 2,500 green tests
saying nothing about it. Coverage measured against the world as it was before the
feature existed proves the feature is not broken only in the ways it used to
not exist.

There are now four such tests, asserting on the argv the production path builds.
The same gap plausibly exists for the dispatcher and swarm surfaces, which have
also never been exercised on another harness — flagged rather than assumed
harmless, since "I don't expect a problem there" preceded both of today's misses.

## `nil` is representable twice, and both spellings bit

Two bugs in one module, same shape:

`backend_for/1` matched the absent case with an `is_atom/1` guard. **`nil` is an
atom.** A surface with no override returned nil rather than falling through to
the global default, so per-surface overrides worked perfectly and the global
default never worked once.

`known_models(nil)` returned `[]` rather than claude's list, because passing nil
explicitly bypasses a function's default argument. Unset is the state every
install starts in — so on a fresh install the model picker was empty.

Both were caught by tests written the same hour, neither by reading the code
twice. "Unset" keeps being expressible as `nil` or as absence, and only one gets
handled.

## Three days of a dev server, and a config it predated

`on-duty` failed with `missing secret_key_base for Google credential vault`. The
config sets it; a fresh VM resolves it; the error was real.

The server serving port 4000 had been running since **Aug 1 12:18** — about 32
hours *before* the commit that added `config :buster_claw, secret_key_base:`.
Phoenix's code reloader swaps modules; application config is read **only at
boot**. So a VM was running modules that call `RuntimeConfig.secret_key_base!/1`
while its own app env had never contained the key.

It surfaced three days late, in a subsystem unrelated to the change, with a
message that reads as "you forgot to configure this" rather than "this VM
predates the configuration". The endpoint's own key was set long ago, which is
why the web UI worked fine and only vault-backed paths failed — a partial
failure that pointed away from the cause.

## The backend roadmap, closed

Two backends existed in code and one existed in practice. Now three do, the
operator picks, and the picks are honest about their limits: harness chosen
globally and per surface, models keyed on `{backend, surface}` so switching is
lossless, per-backend stream parsers built from **captured** output, and the
harness recorded on the audit trail for every money-surface run (the last open
item from the floor problem).

Archived to `08-04-26-agent-backend-roadmap.md`. Two items went to LEFTOVERS with
the prerequisites that make them real work rather than one-liners: **cost
aggregation** cannot be per-surface until the dispatcher and swarm stop dropping
their result event on the floor (three of six surfaces would silently total
zero), and **`opencode models` must be cached** before anything calls it, because
today the only thing keeping a subprocess spawn out of a LiveView render is a
docstring.

Two probes were never settled and are named as the first work if this reopens:
whether `codex exec --ignore-user-config` can scope MCP to Robinhood alone, and
whether an OpenCode agent file's permission patterns reach individual MCP tool
names. Both decide whether per-backend confinement is buildable at all — which is
what the pin is waiting on.

## The day in one line

Yesterday's lesson was *measure the tool rather than quoting the last person who
did*. Today's is its other half: **a green suite is evidence about the questions
it asks, and a new capability arrives with its own questions unasked.** Both bugs
that reached the operator were in code paths no test had ever walked, in a suite
that had grown by two hundred tests that week.
