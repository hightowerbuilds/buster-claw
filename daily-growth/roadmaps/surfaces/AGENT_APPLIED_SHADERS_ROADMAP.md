# Agent-applied shaders — letting the model put a workspace pattern on screen

**Scoped 08-15-26 · Status: COMPLETE 08-15. Phase 0 decided by the operator,
Phases 1–5 built the same day. `nebula` — the shader whose refusal started this —
applies by command after one click.**

> **What shipped.** `background_set` accepts a workspace shader whose **current
> bytes** the operator has approved by applying it once themselves; editing the
> file withdraws that. Shaders already in the workspace were backfilled. The
> store is `BusterClaw.Appearance.ShaderApproval`, in `app_settings`, outside the
> workspace so nothing with file write can forge an approval.
>
> **The property that survived:** GPU code no human has ever looked at cannot
> reach the screen from a command. "Never apply a workspace shader" was only ever
> a proxy for that, and a crude one — it refused the operator's own files too.
>
> **One contradiction the build found.** IV.1 and VI.2 both suggested answering
> the whole catalog with one read of the approval map. It cannot be done: the map
> holds the hash that *was* approved, not whether the file still matches, so an
> edited shader would report `approved: true` and then be refused — the exact
> round trip VI.2 exists to prevent. `background_list` re-hashes per shader.
> `approved_shaders/0` is an inspection API and now says so.

> ### The one-sentence version
>
> **`background_set` refuses any shader that isn't built in, so the model can
> write `shaders/nebula.wgsl` but cannot apply it — and the operator wants that
> changed without simply deleting the property that makes it safe.**

> ### The operator's ask, verbatim
>
> *"Ok put the nebula shader patter on the homepage"* → refused → *"Hmmm. We
> want you to be able to do that yourself."*

> ### Read this before planning around it
>
> **The refusal is not a gap. It was added deliberately on 08-15, the hour the
> `background_*` verbs landed, because this tutorial's own claim went false**
> (`DMG-review-8-15`). Three tests, two catalog moduledocs and one Explained
> page all assert it. Removing it is a four-file edit; removing it *without
> making the app tell a lie* is what this roadmap is actually about.

---

## Contents

- [Part I — What the code says today](#part-i--what-the-code-says-today)
- [Part II — Why the obvious fixes don't work](#part-ii--why-the-obvious-fixes-dont-work)
- [Part III — The five options](#part-iii--the-five-options)
- [Part IV — Recommendation: approval by content hash](#part-iv--recommendation-approval-by-content-hash)
- [Part V — The phases](#part-v--the-phases)
- [Part VI — What has to change beyond the check](#part-vi--what-has-to-change-beyond-the-check)
- [Part VII — Risks](#part-vii--risks)
- [Part VIII — The operator's answers](#part-viii--the-operators-answers)

---

## Part I — What the code says today

### I.1 — The refusal, and exactly where it lives

`lib/buster_claw/commands/appearance.ex:158` — `refuse_authored_shader/1`, run
from `set/2` at `:123` *before* `Appearance.set_background/2`:

```elixir
defp check_shader(name, true) do
  if name in Appearance.builtin_shaders(),
    do: :ok,
    else: {:error, authored_shader_refusal(name)}
end
```

`Appearance.builtin_shaders/0` is `smoke`, `waves`, `mandel`, `weather`, `veil`.
Everything else in the catalog — all 22 files in the DataZone `shaders/` folder —
is refusable, whoever wrote it.

The check is deliberately narrow (`:152-157`): it fires **only** for a shader
`Appearance` would otherwise have accepted. A shaderface, a deleted file or a
typo falls through to `Appearance`'s own better-worded refusals.

### I.2 — It catches the overlay path too

`shader_component/1` (`:183-192`) pulls the shader out of `image:<slot>+<shader>`
as well as a bare name, so an authored shader cannot ride in as an image
overlay. `appearance_test.exs:295` is that attack, written as a test.

### I.3 — Three tests hold it

| Test | Line | Asserts |
|---|---|---|
| "a shader the agent wrote itself cannot be applied by command" | `:277` | refusal mentions `workspace`, `Settings → Appearance`, `smoke`; surface does not move |
| "an authored shader cannot ride in as an image overlay either" | `:295` | same via `image:<slot>+<shader>` |
| "built-in designs and the operator's own images stay selectable" | `:311` | the refusal didn't over-fire |

`:277` is written as an *attack*, not an assertion, and its comment names the
regression it was born from.

### I.4 — Three docs make the claim in prose

- `Explained.Shaders` (`:6-22`) — *"a `shaders/<name>.wgsl` written by anything
  with workspace access stays a **proposal** until a human clicks it in
  Settings → Appearance."* This is a user-facing tutorial.
- `Catalog.Appearance` (`:12-22`) — the split between selection and authoring.
- `Catalog.TerminalTheme` (`:15`) — *"only a human click may put user-authored
  GPU code on a screen."*

**Any change here edits prose the operator reads in the app, not just code.**

### I.5 — The current state, for reference

`app_settings.home_background_mode` = `mandel` (set 08-12).
`nebula` is in the catalog with `filled: true`, so the file is valid and the
page can apply it today. Only the command surface can't.

---

## Part II — Why the obvious fixes don't work

### II.1 — Tiers don't separate the operator from the agent

`commands.ex:101-107` defines `:trusted | :agent_untrusted | :agent | :mcp`.
`background_set` is `:restricted`, so `:agent`/`:mcp` tokens already can't call
it at all.

**But an agent driving `POST /api/run` with the loopback dev token authenticates
as `:trusted`** — the same tier as the operator's own CLI. That is how this
session reached the refusal in the first place. So "allow it for trusted
callers" grants exactly nothing new: the guard was written *because* tier
already fails to separate these two.

This is the single most important finding in this document. Any design that
routes around it by tier is solving a different problem.

### II.2 — "No verb authors a shader" was already tried, and is insufficient

Recorded verbatim at `appearance.ex:144-148`: the containment argument for
leaving `background_set` ungated was "no command authors a shader." True, and
not sufficient — **authoring is a file write**, and the workspace is writable.
Any design whose safety rests on "the agent can't create the file" is repeating
a mistake this codebase already made and caught.

### II.3 — A confirmation argument is theatre here

`Catalog.Appearance:30-38` argues, well, that gating a background is theatre —
a confirmation dialog for an act that is *visible the instant it happens and
undone by one more call* trains the operator to click through gates that matter.
A `confirm: true` argument would be worse: it is a string the model types.

---

## Part III — The five options

| # | Option | Preserves the property? | Operator friction | Verdict |
|---|---|---|---|---|
| A | Delete `refuse_authored_shader/1` | No | none | Honest but total surrender |
| B | One-time consent flag in settings | Once flipped, no | one click, ever | Simple; all-or-nothing |
| C | Per-call `confirm` argument | No | none, and false comfort | Reject — see II.3 |
| D | **Approval by content hash** | **Yes** | one click per shader version | **Recommended** |
| E | Proposal queue + one-click apply | Yes, literally | one click per apply | Good, more UI |

**A** is the operator's ask taken at face value. It is defensible — this is a
single-user machine and the "attacker" is the assistant they invited in — but it
falsifies a tutorial and deletes three tests, and it means any future prompt
injection that reaches workspace write also reaches the screen.

**B** is a settings key (`appearance_allow_authored_shader_commands`, default
false). Cheap, and the consent is real and revocable. Weakness: once on, it's on
for every shader forever, including ones written five minutes from now by a
compromised run.

**D** is Part IV.

**E** keeps `Explained.Shaders`' word "proposal" literally true by making it a
real noun: a `background_propose` verb that raises a notification the operator
clicks. Strictly the safest, and the most new surface to build. Worth doing if
the notification rail is going in anyway.

---

## Part IV — Recommendation: approval by content hash

### IV.1 — The idea

Store, **outside the workspace**, the set of shader files the operator has
approved — keyed by a hash of the file's contents. `background_set` accepts a
non-built-in shader when its *current* content hash is in that set.

- Operator clicks a workspace shader in Settings → Appearance → the app records
  `sha256(file)` as approved.
- The model may then apply that shader by name, freely, forever.
- **The model edits the file → the hash changes → it needs a click again.**

### IV.2 — Why this is the right shape

It matches the actual threat model instead of a proxy for it. The danger was
never "an agent selected a background"; it was **"GPU code no human reviewed
reached the screen."** A hash-keyed approval set says exactly that and nothing
more.

Three properties fall out for free:

1. **`nebula` works after one click.** The operator's ask is satisfied for every
   shader they've ever chosen, which is the realistic set.
2. **Live tuning stays honest.** "Let me adjust the nebula's drift speed" —
   currently pitched as a thing the model can do live — correctly drops back to
   needing a click, because the code changed.
3. **The store is outside the workspace**, so an agent with file write cannot
   forge an approval. This is the part that makes it different from a manifest
   file in `shaders/`, which would be self-certifying and worthless.

### IV.3 — What it costs

The friction is real and should not be undersold: **every edit re-arms the
gate.** An iterative "tweak, look, tweak" loop becomes tweak-click-look. If the
operator wants unattended iteration, D is the wrong option and B is the right
one. **That trade was answered on 08-15 and the answer is that iteration is not
wanted** — see [Part VIII](#part-viii--the-operators-answers), which is why this
cost is priced at roughly zero rather than at the loop it would otherwise break.

---

## Part V — The phases

### Phase 0 — Decide (operator, blocking) ✅ DECIDED 08-15

**Option D, with the 22 existing shaders backfilled as approved.** The full
answers and the reasoning are in [Part VIII](#part-viii--the-operators-answers).
Phases 1–5 are unblocked; budget two to three days.

### Phase 1 — The approval store ✅ SHIPPED 08-15

New functions on `BusterClaw.Appearance` (**not** in `commands/`, see VI.1):

- `approve_shader(name)` — hash the file, record it
- `shader_approved?(name)` — hash the file, compare
- Approvals live in `app_settings` under one key, a map of `name => sha256`.

Hash the **file bytes as served**, not the catalog entry. A deleted-and-rewritten
file must not inherit approval.

### Phase 2 — Wire the page ✅ SHIPPED 08-15

`AppearanceLive` calls `approve_shader/1` whenever a human applies a workspace
shader. This is the only place approval is minted. **Backfill on first run: YES**
(VIII.3, decided 08-15) — every shader present in `shaders/` at the migration is
approved at its current hash, so the feature works on day one instead of after
22 clicks. A file written *after* that point is new and needs its click.

> **Correction, 08-15: the backfill is Phase 1's, not Phase 2's.** It lives in
> `ShaderApproval.backfill/0` and runs lazily on first read, because it needs
> `Shaders.list/0` and the stamp key — both the store's business, neither
> `AppearanceLive`'s. This paragraph is where the *decision* is recorded; the
> code is one phase earlier.
>
> **A consequence for anyone writing tests here.** The store backfills
> everything present the first time it is asked anything, so a test that writes
> a shader and then clicks it will pass on the day-one grant and never exercise
> the click path at all. Force the backfill first (read `approved_shaders/0`, or
> stamp the marker key) and then write the shader under test. This ate a real
> test during the build.

### Phase 3 — Relax the command check ✅ SHIPPED 08-15

`check_shader/2` becomes: built-in **or** `Appearance.shader_approved?(name)`.
The refusal sentence in `authored_shader_refusal/1` (`:194`) needs rewriting —
it currently says commands may *never* apply workspace shaders, which would
become false. New wording must tell the caller the fix: *click it once in
Settings → Appearance and this command will work from then on.*

### Phase 4 — Correct the prose ✅ SHIPPED 08-15

Non-optional, and the reason this is a roadmap and not a patch:

- `Explained.Shaders:6-22` — "stays a proposal until a human clicks it in" is
  still true *for a shader the operator has never applied*. Say that precisely.
- `Catalog.Appearance:12-22` and `Catalog.TerminalTheme:15` — the "only a human
  click" sentence needs the same qualifier.
- `appearance.ex:132-157` — the comment block explains why the check exists;
  it must explain why it now has an exception.

### Phase 5 — Tests ✅ SHIPPED 08-15

`appearance_test.exs:277` and `:295` keep their names and their meaning: an
**unapproved** shader the agent wrote is still refused. Add:

- an approved shader applies by command
- editing an approved shader's file revokes it (the hash test, and the one most
  likely to be quietly skipped)
- approval does not leak across names, or from bare shader to `image:+overlay`

---

## Part VI — What has to change beyond the check

### VI.1 — The reach list will fail you

`appearance_test.exs:28` holds a **name-blind reach list** read from the
compiler's record of what `Commands.Appearance` calls. A direct settings write
appearing in that module fails the test *whatever it is named*. The Pockets
mount suite carries a D4 guard that greps every file under `commands/` for a
settings write and **greps source**, so it cannot tell a call from a sentence
describing one.

**Consequence:** the approval lookup must be a function on `Appearance`, and
`commands/appearance.ex` must not name the settings store even in a comment.
Budget an hour for this alone if you find it the hard way.

### VI.2 — `background_list` should report it

An option entry gains `approved: true|false` so a caller can tell "I may apply
this" from "I must ask." Without it the model discovers the boundary only by
being refused, which `Catalog.Appearance` already argues is bad manners.

### VI.3 — Two surfaces, one rule

`terminal_background_mode` sits on the same table. Whatever is decided applies
to both, and `Catalog.TerminalTheme` carries the twin sentence.

**Free, as built (08-15).** Approval is keyed by shader *name*, not by surface,
so applying a workspace shader to the Terminal grants exactly what applying it
to the Homepage grants. No extra code — and worth knowing before someone writes
a per-surface approval test, which could not fail and would be scenery.

---

## Part VII — Risks

1. **The tutorial becomes subtly wrong rather than loudly wrong.** A false
   sentence in `Explained.Shaders` is worse than no sentence; it is the exact
   failure mode that produced this guard on 08-15. Phase 4 is not cleanup.
2. **Approval is invisible.** The operator clicks a shader to *see* it, and
   silently grants a standing capability. The Settings row must say so.
3. **Hashing cost on every set.** Files run to 46 KB (`hightowerbuilds-face`).
   Negligible, but don't hash in a render path.
4. **This is the assistant asking for its own permissions to be widened.** Worth
   naming plainly. The request is reasonable and the operator initiated it — but
   the person who wrote the guard and the person now removing it should be the
   same person, and that is the operator, not the model.

---

## Part VIII — The operator's answers

**Answered 08-15.** Recorded with the reasoning, because VIII.2 turned out to be
the question the whole choice hung on, and the first reading of the ask got it
backwards.

**VIII.2 — Does live shader tuning matter more than the gate? → NO.** Taken
first because it decides the rest. The operator's clarification, verbatim: *"we
dont want the model to iterate like that. we just want the model to change the
background selection. this is seperate from the creation of shader patterns."*

That removes D's only real cost. This document's own text conceded that "if the
operator wants unattended iteration, D is the wrong option and B is the right
one" — and a session reading the original ask (*"we want you to be able to do
that yourself"*) argued exactly that, on the assumption of a
tweak-apply-look loop. **There is no such loop.** The friction D imposes falls
entirely on a workflow that is not wanted.

**VIII.1 — Which option? → D.** Selecting a pattern that already exists and
running code the model wrote a minute ago are different acts, and that is the
distinction the operator drew unprompted. D is the only option that draws the
same one: A and B erase it, E builds a proposal flow for proposals nobody wants
to make.

**VIII.3 — Backfill the 22? → YES**, and this is what makes the feature match
the ask on day one rather than after 22 clicks. Those files are already on the
operator's machine and most have been applied at some point; making them click
each again buys nothing, because every one of them predates the question. With
the backfill, `nebula` — the shader whose refusal started this — works
immediately, which is the actual request.

**VIII.4 — Extend to `sound_apply`? → Still out of scope.** Unchanged.

> **Why the hash, given VIII.2.** Worth restating now that iteration is not the
> point, because the reason changed: the hash is **not** there to police
> tweaking. It is there because names are forgeable. Approving by name alone
> would let a run overwrite `nebula.wgsl` with different contents and apply it
> under an approved name — the same file-write shortcut that made
> [II.2](#ii2--no-verb-authors-a-shader-was-already-tried-and-is-insufficient)
> insufficient. The hash is what makes "this exact pattern" mean anything.

---

## Appendix — Files this touches

| File | Why |
|---|---|
| `lib/buster_claw/appearance.ex` | approval store, `shader_approved?/1` |
| `lib/buster_claw/commands/appearance.ex` | `check_shader/2` `:167`, refusal `:194`, comment `:132-157` |
| `lib/buster_claw/commands/catalog/appearance.ex` | moduledoc `:12-22` |
| `lib/buster_claw/commands/catalog/terminal_theme.ex` | twin sentence `:15` |
| `lib/buster_claw_web/components/explained/shaders.ex` | tutorial `:6-22` |
| `lib/buster_claw_web/live/appearance_live.ex` | mint approval on click |
| `test/buster_claw/commands/appearance_test.exs` | `:277`, `:295`, `:311`, reach list `:28` |
| `introduction/07-notify-memory-shaders.md` | **the document the MODEL reads** — rewritten 08-15 and missing from this table until then. It now states the rule as "only the five built-ins, whoever wrote it", which Phase 3 makes false. Phase 4 is incomplete without it: correcting three docs the operator reads and leaving the model's own briefing wrong inverts the point. |
| `test/buster_claw/introduction_test.exs` | asserts that briefing verbatim, including the rendered built-in list derived from `Appearance.builtin_shaders/0`. **Phase 3 turns it red**, which is the guard working — it exists to force the briefing to be re-edited rather than drift. Expect it; do not weaken it. |
