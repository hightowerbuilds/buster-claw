# 08-15-26 — The DMG opened, and the app told on itself

A signed DMG on the Desktop, four findings, three requested builds, and all of it
closed in a day. But the two things worth remembering are that **a one-line bug
report was a three-form bug**, and that **a feature I shipped in the morning
broke a security property that a documentation test caught in the afternoon.**

| Shipped | Commit |
|---|---|
| First signed DMG — Developer ID, hardened runtime, entitlements on `beam.smp` | — |
| Voice tab: the Ramshackle surface, your library of words | `7d10b3a` |
| **Agent CLIs found on the login-shell PATH, not launchd's** | `6661021` |
| Configuration gets a rail; `settings_live.ex` 936 → 643 | `0d4a920` |
| `background_list` / `background_set` — and the D1 hole they opened, closed | `09343be`, `d2f6ffa` |
| A Pockets tutorial, the ninth | `d2f6ffa` |
| `phx-submit` everywhere Enter could navigate away | `6994407` |
| Appearance: an overlaid image still marks its tile | `089494e` |

---

## The DMG, and what only a package could say

Signed with the Developer ID and hardened runtime, **24 Mach-O objects signed in
the OTP tree**, and — the check that matters — all four entitlements verified on
`beam.smp` itself. Entitlements do not inherit across process boundaries and the
BEAM is spawned separately, so signing the shell but not the ERTS fails nowhere
in our pipeline and everywhere in the user's.

Opening it produced three findings in about ten minutes, which is roughly three
more than the previous week of reading produced.

---

## Findings 1 + 2: the app could run what it said was missing

Configuration reported claude, codex and opencode **all not installed** on a
machine carrying all three, so no app-wide model could be set.

`System.find_executable/1` searches *this process's* PATH, and a double-clicked
`.app` inherits launchd's — roughly `/usr/bin:/bin:/usr/sbin:/sbin`. Every real
install lives elsewhere: `~/.local/bin`, `~/.bun/bin`, `/usr/local/bin`.

**The app was already right one layer over.** `AgentRunner` spawns through a
*login* shell precisely so a packaged run reaches the user's PATH — so it could
run a harness it reported absent. Detection just asked the wrong thing.

> **And my first measurement of the fix was wrong in a way that looked right.**
> I ran `$SHELL -lc` from an interactive shell that had already inherited PATH,
> saw all three resolve, and called it proven. Replaying launchd's environment
> with `env -i` tells the truth: a zsh **login** shell sources `.zshenv`,
> `.zprofile`, `.zlogin` — and **not `.zshrc`**, which is the only file touching
> PATH on this machine. `-lc` alone would have closed finding 1 against a
> *different* claude binary and left finding 2 open for codex. The flags are
> `["-lic", "-lc"]`.
>
> **A measurement taken in the wrong environment is a guess wearing a number.**

Two more defects fell out of reviewing that module rather than trusting it: the
`Task.async` rescue sat in the *caller*, which cannot see across a process
boundary, so a non-executable `$SHELL` would have killed a LiveView; and caching
a failure forever pinned "no harness installed" for the life of the process.
Profiles also **print** — a banner welds itself onto the PATH with no separator a
trim survives, so the value is read from between fence markers now.

---

## Finding 3: one report, three forms, and a category the suite cannot see

Reported as "the Voice tab closes and throws me back to Chat." Nothing crashed —
a form with `phx-change`, a text input and **no `phx-submit`** is submitted
*natively* by the browser on Enter, so the page navigated and the LiveView
remounted.

Rather than patch the one form, all 57 were measured: **14 carried `phx-change`
with no `phx-submit`, and 3 had a text input.** The third was the Appearance
custom-theme editor, where Enter would have reloaded the page and taken a
half-built palette with it. Unreported, same bug.

The ⌘P switcher looked like a fourth and was already safe via a hook calling
`preventDefault()` — **and got `phx-submit` anyway**, because a hook protects
only while attached and this app has a documented window where it is not.

> **LiveView tests cannot see this class at all.** `render_change/2` and
> `render_submit/2` push events straight at the process; neither involves a
> browser. The guard reads source, like the phx-hook one.

---

## The regression I shipped, and the tutorial that caught it

`background_set` landed with a containment argument: *no command authors a
shader*. True. **Insufficient — because authoring needs no command.** The
workspace is writable, so an agent writes `shaders/x.wgsl` and asks for it by
name, and arbitrary agent-authored GPU code renders on the operator's screen
with no human click. That is exactly the D1 property the Shaders tutorial
teaches.

It surfaced because building the **Pockets** tutorial turned that tutorial's
central claim false. A documentation lockstep found a security hole that a
careful reasoned argument had walked straight past a few hours earlier.

Closed in the **command** layer, not in `Appearance`: the page must keep applying
workspace shaders because a human is choosing there. The command surface is
deliberately the narrower one, and the guard is the attack — a test writes a
shader the way an agent would and asserts refusal, bare and as an overlay.

---

## Smaller, and still worth the line

**The Voice tab shipped** with the vocabulary and sentence-check panes, reading
the real corpus: 237 words, 655 takes, `about` at one take reading *quote only*,
`margarine` missing. Neither pane needs a microphone, which is why it could ship
ahead of the recorder.

**Configuration split** 936 → 643 with a rail, models first — deliberately, since
that is where the "greyed out means not found" sentence belongs, so findings 1
and 2 got their explanation written once instead of twice. A test caught a bug
the split introduced: `SplitLive` mounts `/settings` through `live_render/3`, and
a child mounted outside the router gets `:not_mounted_at_router` where params go.

**Four agents ran in parallel** on disjoint scopes, with one rule changed from
last time: nobody touched `check_file_sizes.sh`. Every cap came back as a report
and I applied them. That was the only real contention point on 08-14 and it did
not recur.

---

## Where this leaves the build

The review is **closed and archived**, with one thing deliberately moved rather
than ticked: findings 1 and 2 are proven **in dev only**. The packaged re-check
is in `QA_BACKLOG`, because a replay of launchd's environment is not the same as
launchd. Two tails — a synchronous `installed/0` in a mount, and no way to
re-check a harness list — are in `LEFTOVERS_PLATFORM`.

Still nobody has opened this app on a machine that did not build it.

**Gates at close:** precommit exit 0 — 3,992 tests, credo clean, 2 accepted
cycles, file-size inventory holds, bun and Rust suites green.
