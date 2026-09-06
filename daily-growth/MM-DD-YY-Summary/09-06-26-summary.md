# 09-06-26 — A review that was wrong six times, and a feature that had never once worked

Eighteen commits. The day started as a code-quality review and ended with the
Vox2B render path, and the thread running through both is the same: **the
things written down were not the things happening.**

Three findings are worth more than the commit list.

- The **shipped brand art is not in the repo**, so a fresh clone builds an app
  with no navigation icons. It needs an operator decision and is not fixed.
- **`AgentToolPolicy` was applied to nothing** — a correct, tested denial list
  that no run has ever carried. It is wired now, and the wiring is worth less
  than it looks; see below.
- **A five-word voice clip had never once rendered on this machine.** Not slow:
  impossible. The deadline was below the cost.

---

## What landed on main

| | |
|---|---|
| `a0d10d0` | The 09-05 code quality review — modularity, dead code, suppression, an 8-phase roadmap |
| `ffc788c` | The generated Tauri ACL is tracked, and CI asserts it matches the build |
| `5ecfee8` | Every script names a runner, so none of them looks like litter |
| `414dd8b` | The 09-05 command count, and one CSS rule with no user |
| `54b7ee0` | **The shipped brand art is not in the repo** — a packaging defect the review missed |
| `f62b225` | `AgentToolPolicy` applied to the unattended run, and what it does not do |
| `a232dd0` · `28559c6` · `a2733a8` | `DataState` and seventeen uncalled functions deleted |
| `89d65e4` | `heartbeat_at` dropped — it was a second copy of `started_at` |
| `c5dcd91` | The unheard count moves to the Phone tab rail |
| `16e4d6e` | Why three uncalled functions are staying |
| `01fdbcd` | The render deadline is measured, not guessed — and a timeout says what it cost |
| `3862eb4` | The recording gets a grade, in numbers read off the samples |
| `2f53d6b` | Vox2B says what a render will cost, before the button |
| `86c0728` | Stop loading a denoiser no render has ever used |
| `9d96b96` | Steps becomes a dial that names its cost — and the cost model gets corrected |

**Gate at close:** `mix precommit` exit **0** — 7 doctests, **4,117 tests, 0
failures**, bun 346/0, credo strict clean, 2 accepted cycles, file-size
inventory holds, docs drift OK, cargo test 43+5+4. **214 commands.**

---

## The review, and the six things it got wrong

The review ran every gate the repo owns and five sweeps it does not: an xref
analysis, an AST pass over every `def`, a whole-corpus identifier index, a
hook↔markup contract check, and a generated-artifact drift check. Its verdict
was that **the architecture is modular and the files inside it are not** — two
core→web edges, both at the application root; zero web files touching `Repo`; a
compile cascade whose deepest sink has two dependents; and against that, six
frozen files and **125 public functions whose only caller outside their own
file is a test.**

Then an agent worked the dead-code inventory and **found six errors in it.**
That is the most useful thing that happened today.

| The review said | The truth |
|---|---|
| `heartbeat_at` is never written | It IS written — by `mark_running/2` and `assignment_attrs/2`, to the *same instant as `started_at`*, never refreshed |
| `unheard_count/0` is not rendered | It is: `Telephony.stats/0` folds it in and `Phone.Log` draws a dot from it |
| `engage_kill_switch/0` has no caller | `duty_live.html.heex:24` → `stand_down/1` → it. It is the only writer of the STOP file |
| The LiveView bypasses `Player.request_*` | It does not. `toggle/1` is a local pure transition; `request_toggle/0` is a remote broadcast. Opposite directions |
| `render_diary/1` is dead | It does not exist. `/2` does, and it is a byte-identity oracle |
| Four arities | `background_mode/1`, `rendered_path/1`, `run_usage/2`, `activity_state/2` |

The review's own warning — *"every no-caller claim is a grep lower bound"* —
was correct and insufficient. **A grep inventory produces false positives as
well as false negatives**, and the false positives are the dangerous half:
a missing entry costs nothing, an entry that says "delete this" costs a
feature. The three-question pass is what caught them, and it is now the reason
the phase existed rather than a ceremony around it.

`heartbeat_at` is the one to remember. Not "a column nobody writes" but **a
column written to the same value as the one beside it** — so
`now - heartbeat_at > threshold` returns the age of the run, not its
staleness. A duplicate wearing a liveness name is worse than a null, because
null cannot be read confidently.

### The denial list narrows the route, not the reach

`AgentToolPolicy` is wired and the wiring is honest about being nearly
worthless on the unattended path. Subtracting `Bash` — unavoidable, since the
Dispatcher's whole mechanism is running `./buster-claw` from a shell — leaves
denied a set with a shell equivalent apiece: `Edit`/`Write` are `cat >`,
`Glob`/`Grep` are `find`/`grep`, `Task` is `claude -p`, and `WebFetch` —
denied everywhere for the loopback SSRF measured 08-03 — is `curl`, against an
endpoint whose URL and token the run is handed on purpose.

What actually binds that path is the provenance token tier, the Sentinel gates
behind `/api/run`, and the per-shift cap. **That is now written into the module
so the list cannot be read as the reason the path is safe.** The review's Phase
0 recommendation was wrong as literally written, and saying so is worth more
than the wiring.

Also measured while there: `--disallowedTools` under `bypassPermissions` leaves
the tools **absent from the toolset**, not offered-and-refused, and the flag is
variadic — emitted before the positional prompt it swallows it and the CLI
dies. Argv order is pinned by a test now.

### The brand art, which nobody has decided about

`.gitignore:39` excludes `/priv/static/images/brand/` deliberately (`551b6fb`,
06-13, "local-only, kept out of the repo"). `Pockets.Brand` declares six
shipped defaults pointing into it. Nothing generates them. `git ls-files`
returns nothing.

So a fresh clone has no navigation icons and no wordmark, and **the packaged
`.app` is built from a checkout** — the R1 DMG ships six missing images unless
whoever builds it happens to have them untracked on disk, as this machine does.
`brand_test.exs:201` already knows and has been red on the ubuntu runner,
inside the failure set attributed to macOS-only tooling.

**A month of red CI hid a shipping bug.** That is `ci_green_after_a_month`
repeating with a different subject. Three exits are recorded in the review;
the choice is the operator's, because it is about asset rights rather than code.

---

## Vox2B: nine and a half minutes, then one word

The operator: *"a phrase for only five words is now taking more than three
minutes… I'm wondering if maybe it's actually just a bug and it's not even
working at all."*

It was not stuck. It was worse: **it could not succeed.** The renderer capped
every job at ten minutes flat, and a clone of `"Take me to the river!"` against
a 13.3-second reference needed longer. It ran 10:28, was killed, and the
surface reported the whole event as `:timeout`. `clips.json` was `[]` — no clip
had ever completed on this machine.

### Why it was slower than the 45-minute batch

The chime set rendered 09-02. The reference was recorded 09-03. `Voice.Config`
says it outright: **with a reference set, every render becomes `clone` rather
than `design`.** The mode changed under him the moment he recorded his voice,
which is the feature working exactly as designed.

### Where the time goes, measured rather than assumed

Three runs of the same line on the i9, watching the engine's own progress bars:

| | 13.3 s ref, 10 steps | 6.0 s ref, 10 steps | 6.0 s ref, 4 steps, no denoiser |
|---|---|---|---|
| model load | ~60 s | ~60 s | ~60 s |
| warm-up | 10 iters | 10 iters at 26.7 s | 10 iters at 20.7 s |
| generation | — | 24.5 s/step | 9.6 s/step |
| **total** | **killed at 628 s** | **585 s** | **380 s** |

Trimming the reference from 13.3 s to 6 s is the difference between a feature
that has never worked and one that does. The rest is arithmetic:

- **The fixed half is paid per invocation**, because the app shells out to the
  CLI once per line. A `batch` subcommand exists and the clip path does not use it.
- **The denoiser was loaded on every render and never called.** Enhancement
  only runs with `--denoise`, which nothing emits. Off now, permanently, with a
  test that greps for the day that changes.
- **Steps scale generation and NOT the warm-up.** Assumed wrong, then measured.

That last one corrected this repo rather than the engine's docs. The first
`Calibration` claimed the step count halved "both halves of the bill" and
multiplied the whole estimate by it. Generation went 24.5 → 9.6 s/step, dead
linear; the warm-up ran ten iterations either way. **585 → 380 s is 65%, not
40%.** The model scales the generation term alone now and predicts 370 against
380 measured.

### What the surface says now

A cost quote before the button, live as you type, from a calibration that
**rescales itself from every render that finishes** — a fixed number cannot be
right for both this i9 and an M4. A deadline at twice the quote instead of a
flat ten minutes. A timeout that says how long it ran, what it was allowed, and
which two things make it finish. And a grade for the recording.

His own reference grades **poor**: −39.6 dB average, peaks at −20.2, 13.3
seconds long, 51% of it silence. It grades **the recording and never the
clone** — nothing has measured how these numbers relate to cloning fidelity, so
the copy says "this recording is quiet", which is measured, rather than "this
will sound bad", which is a guess wearing its clothes.

---

## What the day cost, and what it taught

**The parallel fan-out failed.** Six agents in six worktrees all died on a
model session limit, mid-task, having committed nothing. Restarting them one at
a time worked. Four of the six worktrees still held their uncommitted work,
which is the only reason nothing was lost — and the reason to check disk before
re-running anything.

**Three guards fired on their author today**, all correctly:

- The renderer's moduledoc documents that a database call from the spawned job
  BLOCKS for the connection timeout while holding the one queue there is — the
  09-05 flake. The first version of the deadline put `Calibration` exactly
  there. It is computed in the caller's process now.
- The renderer's guard test forbids an unmonitored spawn in that file. It
  caught the calibration write, and then caught a **comment quoting the call**.
  Left crude on purpose: a guard that cannot be tripped by prose has a parser
  in it.
- The file-size gate refused a feature landing whole inside a frozen file, and
  the answer was a real extraction — 148 lines into `vox/quality.ex` — before
  the residual +27 raised a cap with the reason written beside the number.

**Two measurements corrected two designs.** A floor-relative speech threshold
marks a signal of uniform level as 0% speech, because its floor and its peak
are the same number. And separation had to become loud-decile-against-quiet
rather than the two sides of a speech/silence split, because at the noise
levels worth warning about every frame lands on the speech side — **the split
reports a clean recording precisely when it is dirtiest.**

## Open, and needing the operator

1. **The brand art.** Track it, make the defaults optional and gate the build,
   or fetch it at build time. Doing nothing is not among them.
2. **The step count default.** Both renders were sent for a listen. 4 steps is
   inside the engine's recommended range and 35% faster; the default is
   unchanged until someone has heard it.
3. **The review's remaining phases** — privatising the 92 test-only-public
   functions, the six duplicate bodies, web-layer purity, the frozen files,
   test hygiene. Four worktrees hold partial work for three of them.
