# Doc Drift — where the app explains itself wrongly

**Scoped 08-09-26 · Status: COMPLETE + ARCHIVED 08-09** (`f5a7be2`). All 25
findings fixed. Gate after the pass: **3,115 tests + 7 doctests, 0 failures**;
Credo strict clean; cycles, file sizes, `check_rust.sh`, `acl_lockstep` and
`secret_provisioning` all green.

> **Read the three seams below before the finding tables.** The tables are a
> record of what was wrong on one day; the seams are what will be wrong next
> time, and they are the reason this document is worth keeping after the fixes
> landed.
>
> **Two open items went to `roadmaps/LEFTOVERS.md`** — a test for the Manual,
> and the two skill seeds plus three job mandates the comb never reached.
> `docs/UML.md` sections 3–5 remain stale from 06-14 and are noted there too.
>
> **This comb was not exhaustive and should not be read as a clean bill.** It
> covered `introduction/*.md`, the Explore panels, `user-guide/`, four `docs/`
> files, the README, the workspace registry and one seed. It did not cover
> `AGENTS.md` past line 110, `BUILD.md`, `DESKTOP_PACKAGING.md`, or the seeds
> listed above. **A finding written from reading is a lower bound** — the one
> guard actually executed here surfaced a 26th candidate within seconds of
> first running.

A comb of every surface that *explains* Buster Claw, checked against the code
that *is* Buster Claw. Scope: `introduction/*.md` (the model's operating guide),
the Explore tab tutorials, `user-guide/` (the in-app Manual), `docs/`, `README`,
the workspace registry's self-description, and the seeds that ship into a new
workspace.

**The organising idea.** Drift is not evenly distributed, and it is not random.
It clusters at exactly three seams:

1. **A feature was deleted and its prose outlived it.** The 08-08 trading-stack
   cut (~22k lines) is the single largest source here — six separate documents
   still describe Trading, Portfolio, MarketData, or Chart Build. Deleting code
   is atomic; deleting the sentences about it is not.
2. **A name was reclaimed.** `notes/` and `sources/` were both retired, then
   both had their names taken over by new live features. `sources/` was caught
   and fixed on 08-03. `notes/` was not.
3. **A collection went empty and a guard went quiet with it.** `ModelPolicy`'s
   floors emptied out; the test that guards the floor UI iterates that map, so
   it now passes vacuously while the hardcoded prose beside it keeps teaching
   floors as a live concept.

Seam 3 is the one worth internalising: **a test that iterates a collection stops
testing anything when the collection empties, and it does so silently.** It goes
green faster than before. Nothing in the suite can tell you it has stopped
asking a question.

---

## Severity

| | Meaning |
|---|---|
| **HIGH** | Misleads the *model* into a wrong action, or tells a *user* to do something that won't work |
| **MED** | Teaches a concept that no longer exists; wastes reader trust but breaks nothing |
| **LOW** | Stale count, omission, or internal comment |

---

## A — What the model reads (`introduction/*.md`)

The command *names* are clean: every one of the ~40 commands named across the
eight sections exists in the catalog, verified by diffing the prose against
`Commands.Catalog`. The drift is all in the prose around them.

| # | Sev | Where | The disagreement |
|---|---|---|---|
| A1 | **HIGH** | `04-startup.md:15` | Tells the model to "wake **Mailman / Research Assistant** via shift assignments". **"Research Assistant" appears nowhere in `lib/`, `priv/`, or the job roster** — it is a role the model is instructed to start that does not exist. "Mailman" exists, but as a *terminal cmd-list role* and startup profile (`COMMAND_SURFACE.md:66`), not a shift assignment. The real roster is `mail-triage`, `voicemail-triage`, `sms-triage` (`jobs/README.md`). |
| A2 | MED | `01-orientation.md:40-58` | The workspace layout lists 9 entries and closes with *"Do not invent new top-level folders; the layout above is the declared one."* The registry (`workspace.ex`) declares **20 live** entries. Missing and live: `backgrounds/`, `sounds/`, `checks/`, `sources/`, `cmd-list/`. The closing sentence turns an omission into an instruction to avoid real folders. |
| A3 | MED | `07-notify-memory-shaders.md` | *"the homepage is the one surface you can extend from the workspace."* False since the Appearance rework: `Appearance` keeps **one** option catalog shared by **two** surfaces (homepage *and* terminal), and a workspace `shaders/*.wgsl` backs either. The section heading ("Homepage shader patterns") and its opening sentence carry the same assumption. |

**Verified correct and left alone**, because each looked wrong and wasn't:
the five `note_*` commands and the "no note delete" claim; `browser_secret_put`
being the right thing to ask the user for (it is `gated: true`, so the model
genuinely cannot self-serve); the shipped shader set (`smoke, waves, mandel,
weather` — matches `@builtin_shaders` exactly); every `finance_*` command
(SEC EDGAR + Finnhub survived the trading cut).

---

## B — The Explore tab

| # | Sev | Where | The disagreement |
|---|---|---|---|
| B1 | **HIGH** | `explore/models.ex` | **The Models tutorial teaches capability floors as a live mechanism. There are none.** `ModelPolicy` has `@floors %{}` and `@claude_only %{}` — both emptied when the trading stack's two money surfaces left on 08-08. Seven separate places still teach floors: the SVG's third rung (`RAISED TO THE FLOOR` / `money surfaces only`), the `aria-label` narrating that rung to screen readers, the figcaption calling it *"the whole argument of this page"*, Example 2 (*"Every surface except the two with a floor… those two read floor"*), and the `surface_rows` comment. Also **"the answer is 'your CLI' six times over"** — `@surfaces` has **four** keys. |
| B2 | LOW | `explore/gws.ex:3,9` | Moduledoc and the inline comment both say **"four** prompt-your-way cycles"; the panel renders **six** (`n={1}`…`n={6}`), and its own body text at line 220 says *"The pattern in all six"*. Someone added two cycles and updated the prose but not the docstring. |
| B3 | LOW | `explore/intro.ex` | *"Use the Chat sub-tab, **right next to this one**."* Home tab order is `chat, notes, calendar, phone, studio, explore, activity` — Chat is first, Explore is sixth. They are five tabs apart. |

### Why B1 survived a test that exists to catch exactly this

`models.ex`'s own moduledoc claims it *"cannot drift from the policy it
describes."* That is true of the **surface list** — `surface_rows/0` reads
`ModelPolicy` — and false of everything else on the page.

The guard in `status_live_test.exs:1409` is:

```elixir
for {_surface, floor} <- ModelPolicy.floors() do
  assert html =~ "floor: #{floor}"
end
```

With `@floors %{}` this loop body never runs. The test passes. The test author
knew — there is a comment saying the loops are *"deliberately vacuous today and
become real the moment one is declared"* — and for the **badges** that is a
sound design: the badge renders from policy, so it is correct by construction
either way.

What nobody noticed is that the *hardcoded prose around the badges* was making
the opposite bet. The badge mechanism is drift-proof; the paragraph explaining
the badge is a string literal. So the page kept teaching a rung of its own
decision diagram that can no longer fire, and the suite had no way to say so.

**Generalisation worth keeping: derive-from-source protects the thing derived,
and nothing else on the page.** A module that earns the right to say "cannot
drift" for one element tends to get read as saying it for all of them.

---

## C — The workspace registry describing itself

| # | Sev | Where | The disagreement |
|---|---|---|---|
| C1 | **HIGH** | `workspace.ex:259-265` | `notes/` is declared `tier: :deprecated`, `owner: nil`, `seed: nil`, noted *"Orphan. Superseded by `journal/`; nothing creates it any more."* **`notes/` is the operator's Markdown vault** — the Notes home tab, the five `note_*` commands, `[[wiki links]]`, backlinks, shipped 08-08. `Notes` creates it on demand (`notes.ex:27`, `File.mkdir_p`). It is not an orphan and `journal/` did not supersede it; the introduction correctly describes them as *different objects with different jobs*. |
| C2 | MED | `workspace.ex:483-487` | `sweep_deprecated/0`'s moduledoc names notes/ as *"one orphan nothing has created for months."* |

### Blast radius — bounded, and worth stating precisely

`sweep_deprecated/0` runs on boot and removes deprecated directories **only when
empty**; a non-empty one is kept and logged, under an explicit rule that
*"decluttering never outranks not destroying someone's files."* And `Notes`
re-creates the directory the next time it touches it.

**So no user data is at risk.** The failure is a boot-time delete-and-recreate
of an empty vault directory, not lost notes. I checked this before writing it up
because "the app deletes your notes folder" would have been the more dramatic
claim and it is not the true one.

The reason it still matters is that **this is the second time**, and the first
time is documented fifteen lines above it in the same file. `sources/` was
reclaimed on 08-03 with this note:

> `sources/` was previously declared `:deprecated` … which meant
> `sweep_deprecated/0` DELETED it whenever it was empty. Leaving that entry in
> place beside this one would have quietly removed an operator's override folder
> the first time they emptied it.

That is a precise description of the `notes/` entry as it stands today. The
lesson was written down and the pattern recurred anyway — which suggests the
durable fix is a check that a live owner's directory name is not also declared
deprecated, rather than another comment.

---

## D — The in-app Manual (`user-guide/`, rendered at `/manual`)

| # | Sev | Where | The disagreement |
|---|---|---|---|
| D1 | **HIGH** | `daily-loop.md:65`, `setup.md:13` | Both tell the user to create jobs in **`job-descriptions/`**. That folder is a *legacy name*: `workspace.ex:367` relocates `job-descriptions → jobs` on boot. daily-loop states it as an instruction — *"Add more jobs anytime by dropping a new `job-descriptions/<key>.md` file"* — so a user who follows the Manual creates a folder the app then moves out from under them. |
| D2 | **HIGH** | `introduction.md` "What's in the app" | The dock is described as nine surfaces including **Split, Calendar, Advanced, Security**. `layouts.ex:8` `@navigation_items` has **five**: Home, Workspace, Browser, Terminal, Settings. Worse, *"**Advanced** — Scheduler, Webhooks/Hooks, Integrations, Delivery, Memory, and Security"* names **four features retired as unused** (`COMMAND_SURFACE.md:89`) under a dock section that does not exist. |
| D3 | MED | `setup.md` | The wizard is described as **3 steps**; `setup_live.ex:32` is `[:welcome, :workspace, :tools, :google, :live]` — **5**, and the missing `:tools` step is the one that checks for the agent CLI, which is the step a new user is most likely to get stuck on. |
| D4 | MED | `introduction.md`, `daily-loop.md`, `README.md` | *"Claude Code (or Codex)"* throughout. **OpenCode is a third supported harness** (`ModelPolicy.backends/0`), selectable globally and per surface since 08-03. |
| D5 | MED | `introduction.md` | *"**Browser** — an in-app reader for fetching/reading web pages (SSRF-guarded)."* It is a real driveable browser: co-presence `browser_*` verbs, Agent Mode with a payment gate, flows and saved checks. The Manual undersells the app's largest feature as a reader. |

---

## E — Repo docs and README

| # | Sev | Where | The disagreement |
|---|---|---|---|
| E1 | MED | `docs/ARCHITECTURE.md:29-31` | Three core contexts listed that no longer exist: `BusterClaw.Trading` (+ `TradingLive`), `BusterClaw.Portfolio`, `BusterClaw.MarketData`. Deleted 08-08 (`293f47f`). |
| E2 | MED | `docs/LOCAL_TRUST.md:13,18` | *"exactly one — Chart Build — is granted exactly one of them, `WebSearch`."* `AgentToolPolicy.denied_builtins/1` now documents the opposite: *"No profile subtracts anything today — `:chartbuild`, the only one that did, left with Chart Build on 08-08."* The **Known accepted risks** section still carries a whole entry for an egress path that no longer exists, citing `ChartBuilder.Fetch`. A security doc overstating a risk is a smaller problem than one understating it — but it also reads as *precedent* for granting `WebSearch` again. |
| E3 | LOW | `docs/LOCAL_TRUST.md:10` | *"untrusted callers (the scoped `:mcp` token)"* — there are **four** tiers (`:trusted, :agent_untrusted, :agent, :mcp`), and `:agent_untrusted` is the interesting one: it may run restricted commands but not gated ones. The doc omits the tier that carries the actual nuance. |
| E4 | MED | `docs/COMMAND_SURFACE.md:87` | Lists **`AgentRunner`** under *"Current Cuts … removed or retired."* `lib/buster_claw/agent_runner.ex` exists and is load-bearing — `ModelPolicy` resolves backends through `AgentRunner.detect/0`. |
| E5 | MED | `docs/COMMAND_SURFACE.md:89` | *"DB-backed Memory — retired as unused."* `BusterClaw.Memory` + the `Memory.RunSummary` Ecto schema back the live, catalogued `memory_search` command, which the introduction tells the model to check before re-deriving anything. |
| E6 | LOW | `docs/COMMAND_SURFACE.md:23-34` | *"Active Domains"* lists 10 and omits telephony/BusterPhone, notes, notify, journal, agent runs, browser control, skills, sound, and music — most of the 191-command surface. |
| E7 | LOW | `docs/UML.md:42` | The domain-context node still reads `Trading & Portfolio & Finance & Research & MarketData`. The file's own header warns sections 3–5 are stale; this is in **section 1**, which the header claims was re-derived 08-02 — true then, overtaken since. |
| E8 | **HIGH** | `README.md` | *"the current build is **x86_64 only**. An Apple-Silicon-native build is in progress."* `LAUNCH_ROADMAP.md:177` records **Two architectures (III.G) — Done**: `macos-15` (aarch64) + `macos-15-intel` (x86_64), each with its own native ERTS. The README tells every Apple Silicon visitor — nearly all of them — that the app runs emulated. |
| E9 | LOW | `README.md` (×2) | *"150+ commands."* The catalog holds **191**, verified by the contract test. |
| E10 | LOW | `README.md` | `mix precommit` described as four steps; `mix.exs:141` runs **eight**, including `check_cycles.sh`, `check_file_sizes.sh`, and `check_rust.sh`. A contributor who trusts the README skips the three gates most likely to fail. |
| E11 | MED | `skill-seeds/README.md` | The file ends with a stray `"""` line — a heredoc delimiter that escaped into the seed. It ships verbatim into `<workspace>/skills/README.md` on every new install, and because seeds go through `maybe_write` (which **never overwrites**), it is permanent per install. See `skills_upgrade_path` — the shipped-defaults problem, in miniature. |

---

## What was checked and found correct

Recording this so the next comb doesn't re-derive it:

- **Every command name in `introduction/*.md`** — diffed against the catalog; no
  phantom commands. The auto-generated `{{COMMAND_SURFACE}}` block keeps
  argument/tier detail honest by construction.
- **Explore's command statistics** (191 total / 77 read / 17 trigger / 97 mutate
  / 80 safe / 111 restricted / 21 gated) — `status_live_test.exs` derives all
  seven from `Commands.list_commands/0` and fails on drift. Ran it: 70 tests, 0
  failures.
- **`explore/browser.ex`** and **`explore/sites.ex`** — clean. Sites keeps
  number vending in the future tense, which is still correct.
- **The corner widget** — `Time & Place / Contacts / Notify`, matching the Intro
  panel's reference to Contacts.
- **`README.md`'s trust-tier table** — matches `commands.ex:101-107` exactly,
  including the `agent_untrusted` / gated distinction that `LOCAL_TRUST.md`
  omits.
- **`memory/policy.md` seed** — its baseline matches the real tier rules.
- **`workspace.ex`'s `extensions/` entry** — correctly marked deprecated after
  the 08-08 deletion. The registry is honest here; `notes/` is the exception,
  not the rule.

---

## What was done

All findings above are fixed. Beyond the direct edits, two things are worth
recording because they changed the shape of the work.

### A guard, not a third comment (C1)

The `sources/` fix on 08-03 left a comment warning about exactly this failure.
The comment did not prevent `notes/`. So this pass added a real guard —
`workspace_test.exs`, *"no deprecated entry is still reached by live code"* —
rather than a third comment.

It reuses the existing layout guard's `lib/`-walker: a `:deprecated` directory
that live code statically reaches for is, by definition, a reclaimed name. Two
design notes:

- **`owner:` is the wrong signal.** It records who owned the directory
  *historically* — `analysis/` legitimately still names a live module. The right
  signal is whether live code builds the path.
- **Directories only**, mirroring `sweep_deprecated/0`'s own filter. On its
  first run the guard flagged `MANUAL.html`, which turned out to be a genuine
  false positive: `Pages.ensure/0` references it in order to *delete* it, and
  files are never swept. Scoping to `:dir` fixes the guard and makes it mirror
  the function it protects.

**Verified by breaking the fix, not by watching it pass.** Reverting `notes/` to
`:deprecated` failed two tests — the registry guard, naming
`lib/buster_claw/notes.ex` as the reclaiming file, and a new behavioural test
that an empty vault survives `ensure/0`. Restored, both green.

Three existing sweep tests used `notes/` as their dead-directory fixture and
were re-pointed at `analysis/` and `extensions/` — a fixture that has quietly
become live is its own small version of this bug.

### The models page now says why it is not safe (B1)

The floor rung is gone from the diagram, its `aria-label`, the figcaption, and
Example 2 — replaced with an accurate statement that the mechanism exists and no
surface declares one. The badges still render from `ModelPolicy` and are
untouched.

The moduledoc no longer claims the page "cannot drift." It now says which half
is derived, which half is string literals, and what happened the last time
someone read the first claim as covering both.

## Owed follow-up (not in this pass)

- **Nothing guards prose that quotes a collection's size.** B1's root cause is
  that `"six surfaces"` and `"the two money surfaces"` were string literals
  beside a list that is derived. The fix removed the literals rather than
  guarding them; a page that *wants* to state a count still has no way to keep
  it honest short of asserting it against `map_size/1`.
- **`docs/UML.md` sections 3–5 are still from 06-14** and have never been
  re-derived. Section 1's domain node is corrected here; the request-flow
  diagrams below it were out of scope for a doc-drift pass and need someone to
  walk the actual routes.
- **The Manual has no test.** `user-guide/` had the worst drift of any surface
  (a dock listing four retired features and two folders that don't exist), and
  nothing in the suite reads it. The dock is a five-item list in `layouts.ex`;
  asserting the Manual names those five and no others is cheap.
