# 08-17-26 — Everything that described the code, then the DMG that made us prove it

The day began as one thread. No feature shipped. What moved first was the layer
*above* the code — the index, the moduledocs, the module names, the roadmap
folder — and every one of them was out of true. It ended at the other edge of
the same problem: asking whether the thing described as releasable was actually
ready to leave this Mac.

The thread started by accident. Filing the Sketch Pad into the SUPERMAP meant
adding a row to **Part II — Home**, and before adding a true row under a heading
I checked the heading. It said *"`StatusLive` at `/`. Eight sub-tabs"*. The
Studio had left Home for its own route the day before.

**Each fix uncovered the next one**, which is the shape of the day:

| Found | By |
|---|---|
| The SUPERMAP filed the Studio under Home | Adding a row beneath the heading |
| Four modules' prose named the wrong LiveView | Tracing the index's claim to its source |
| Three module *names* were leftovers | Fixing the prose and finding the name still lied |
| Five finished maps still sat in `roadmaps/` | Looking at the folder the SUPERMAP indexes |
| A guard existed only in prose | Reading a map I was about to archive |

---

## The measurement that made it a fact rather than an impression

`StatusLive` holds **zero** studio assigns. `StudioLive` holds **eighteen**.

That is the whole diagnosis, and it took one grep. Everything after it was
mechanical; the reason it had not been done is that nothing *looked* wrong.

Four modules were saying otherwise:

- `StudioPanel` opened with *"The home Studio tab"* and said `StatusLive` handles
  `select_studio_tab`
- `SoundStudioComponent` said `StatusLive` owns `@studio_source`, illustrating the
  cost with *"lost every time you glanced at Chat"* — a tab no longer beside it
- `Status.Studio` said *"every one of these assigns lives in `StatusLive`"*
- `sound_studio.ex` tells **the operator**, in a workspace document they read,
  that the Studio is "the Studio tab on the home page"

That last one is the one worth minding. Three were maintainer comments; one was
user-facing prose in a file shipped into their workspace.

> ### Why this kind of drift is invisible
>
> **The reasoning survived intact in every case.** State lives in the LiveView
> rather than the component because a sub-tab's `:if` discards the component —
> as true at `/studio` as it was at `/`. Only the surface it applies to moved.
>
> So each paragraph still *reads correctly*. The argument is sound, the
> mechanism is real, and every proper noun in it is wrong. There is nothing for
> a careful reader to trip on, which is exactly why it survived a day of people
> working in those files.

The roadmap got the same treatment, split two ways: the live claim about where
assigns live was corrected, and `VI.0b` — *"two sub-tabs inside the home Studio
tab"*, answered 08-09 by the operator — was **kept as written with a supersession
note**. It was true when decided, and its reasoning is what actually got built.
Rewriting history to match the present is how a record stops being one.

---

## The rename, and the collision inside it

The prose fix deliberately left one thing: three modules served `StudioLive` from
under `live/status/`, named for a LiveView that holds none of their assigns. That
is a leftover *name*, not a false statement, and it got its own commit.

Good thing, because **the obvious rename had a collision in it.**
`BusterClawWeb.Studio.Recorder` already exists — the recorder's *markup*, in
`components/studio/`. `Status.Recorder → Studio.Recorder` would have landed on
top of it.

And that component has aliased the state module `as: State` since it was written.
**The tension was already being felt and worked around; it had just never been
named.** A regex sweep would have hit it head-on.

```
Status.Studio   → Studio.MixState        live/studio/mix_state.ex
Status.Voice    → Studio.VoiceState      live/studio/voice_state.ex
Status.Recorder → Studio.RecorderState   live/studio/recorder_state.ex
```

`MixState` is also more honest than `Studio` was — it is the Mix arranger's
state, not the Studio's.

**Call sites did not move.** Every `alias` gained `as: Recorder` / `as: Voice`,
this repo's own extraction pattern from the TradingLive split. 64 lines across 16
files for a rename touching 43 references — almost all of it aliases, moduledocs
and paths.

Two more things a sweep would have missed: `check_file_sizes.sh` names **file
paths**, not modules, so a rename without it fails the gate with *"capped here
but does not exist"* — the same failure another session hit this week. And the
dated summaries reference the old names and were left alone.

---

## Archiving, and the item that archiving does not close

Five maps had finished and were still sitting in `roadmaps/`, which the SUPERMAP
indexes to answer *"where is the build?"* A finished map in that list is a wrong
answer that costs a read.

Three closed empty. **Two closed with an item outstanding**, and those are the
ones worth being careful about: `APP_ICON`'s Dock walk and `TERMINAL_THEME`'s
operator walk. Both maps *said* their leftover was filed elsewhere. I checked
that it actually was — in `QA_BACKLOG` and `RELEASE_GATE` respectively — before
moving either.

**Archiving closes a map, not an item.** A map that says "filed in X" and is
wrong takes its open item with it into the archive, where nobody looks.

Each archived map's header keeps the thing worth remembering rather than a
summary. The best is `OUTBOUND_VOICE`'s: **Phase 2 was deleted by the build, not
skipped.** It scoped a public endpoint serving `<Dial>` TwiML behind a signature
check; Twilio's API takes the document inline, so the phase and its headline risk
disappeared together. *There is no public endpoint to abuse because there is no
public endpoint.*

---

## And a guard that existed only in prose

`UPDATE_ROADMAP`, written yesterday, says the update path is never a command at
any tier — because an agent that can replace the application binary can replace
every boundary that refuses it. Then it says:

> `test/buster_claw/commands/update_test.exs` asserts no catalog entry matches
> `update_*` … and fails if one ever appears.

**There was no such file.** The rule was already being cited as if enforced,
one day after being written, in a map I was about to archive past.

That is the exact failure the rule is *about*. Its whole enforcement is an
absence, and an absence rots silently — which is the sentence the map itself
uses to argue for the test it did not have.

Written now, and broken three ways to check it. **The first version was wrong in
the other direction**: matching the substring `update_` caught
`sheets_update_values`, one of twelve legitimate catalog commands with "update"
in the name. A guard that cries wolf on a dozen real verbs gets an exception list
until it guards nothing. It matches on the **object** now — twelve commands
contain "update" and none begins with it, so a leading `update_` is unclaimed and
is the shape an app updater would take.

Also fixed: `UPDATE_ROADMAP` still said *"Status: SCOPED, no code"* a day after
`G-42` and `G-18` shipped. My own stale header, one day old, in the middle of a
day spent on exactly that.

---

## What today says about the last two weeks

Six artifacts drifted, and **not one of them was code**. The tests were green
throughout — 4,203 of them by the end — because nothing being described had
broken. What had broken was every description of it.

The repo already had this lesson filed at three seams: *a deleted feature's prose
outlives it · a name gets reclaimed · a collection empties and its guard goes
vacuously green*. Today adds a fourth, and it is the one that produced all of
today's work:

> **A surface moves, and its prose stays.** The argument survives the move
> intact — which is why nobody notices — and every proper noun in it goes wrong
> at once.

The other three seams are found by reading. This one is not, because reading is
what makes it look fine. It is found by **checking a claim against the code** —
`StatusLive` holds zero studio assigns — or by trying to add something beside it
and having to ask whether the heading above is still true.

**And a staging note, because it nearly cost something.** The archive commit's
first `git add` used directory paths and swept in six of another session's files
— an untracked roadmap of theirs, a deletion of theirs, four archive edits that
predate this session. Caught by reading the staged diff before committing.
Directory-level `git add` in a shared tree is how that happens, and the staged
diff is the only place it shows.

---

## The DMG is real. The release is not.

The second thread began with a concrete question: **can we build a DMG, put it
on the Buster Claw website, and copy it to the Desktop?** The honest answer split
in two.

**We can build and exercise a local candidate. We cannot publish that candidate
as the release.**

The host has the whole build toolchain and enough disk. The app compiled into an
Intel `x86_64` bundle, Tauri produced a DMG, `hdiutil verify` accepted its
checksum, and the macOS-floor gate found 25 Mach-O files with no requirement
above the advertised macOS 14.0 floor. The bundled BEAM booted, served Phoenix,
rejected a bad token, and exposed 218 production commands.

Then the packaged shell itself passed the part that actually matters. It opened
its loopback listener, connected the ScreenshotBridge, rendered real
`example.com` text through the hidden webview, and launched installed Chrome
through the CDP pipe, navigated it, read back `bc-probe`, and shut it down. The
HTTP and CLI command surfaces also completed end to end against the packaged
release.

That last sentence took three attempts, and the bundle was not the problem.
`smoke_command_surface.sh` still demanded `source_list`, `provider_active`, and
`chat_send` — commands deleted in the 05-31 terminal-driven cut — and still
called `POST /mcp`, deleted in the 06-09 agent-harness cut. The release smoke had
spent more than two months asserting that removed architecture still existed.
It now uses `document_list`, `integration_list`, and `dispatch_list`, and tests
the two surfaces the app actually ships: HTTP and the CLI. `smoke_desktop.sh`
had one smaller fossil of the same kind: it treated the now-specific
`browser: no active browser tab` reply as bridge failure. That named error is
proof the desktop answered, so the smoke recognizes it before performing the
definitive positive render.

### The dependency gate found something the ordinary suite could not

The first `mix precommit` was green — 4,203 Elixir tests, 352 JavaScript tests,
and 46 Rust tests — but `mix deps.audit` was not. `Req 0.5.17` carried two
advisories, including a high-severity decompression issue, and `hackney` carried
four. Hackney existed only under stale `tzdata` baggage; the application already
uses Elixir's built-in calendar database and no code used Tzdata.

Tzdata and its unused chain are gone. Req is now `0.7.2`, with Finch, Plug, and
Plug Crypto updated beneath it, and the dependency audit reports no known
vulnerabilities. Req 0.7 also removed the private redirect-step state that
`URLGuard` had been reaching into. The guard now relies on Req's current
contract — request steps naturally run again on every redirect — and all 25 URL
guard tests passed, including blocked redirect targets, per-hop DNS
re-resolution, and IP pinning. Dialyzer is green after the adaptation.

The docs-drift gate exposed one more false signal. Mix compilation-status text
was being captured as if it were generated command-catalog content, inflating
217 commands to 219 depending on whether the project had just compiled. The
generator now prefixes only real catalog lines before the shell filters them;
the documented development catalog remains 217, while the packaged production
catalog legitimately reports 218.

### Why the website did not receive this file

This Mac has no Developer ID signing identity and none of the notarization or
updater-signing credentials. The build therefore says exactly what it is:
**unsigned**, not notarized, Intel-only, and unsuitable for another Mac. The
release workflow is the path that builds both Intel and Apple Silicon artifacts,
signs and notarizes them, staples the result, and emits updater metadata — but
there is no release tag, the working tree contains multiple sessions' uncommitted
work, and local `gh` authentication is invalid.

Those mechanical blockers are not the whole no-go. The release ledger still has
the real Amazon checkout/payment-stop walk open, plus packaged first-open and
media walks, signed/notarized two-architecture verification, and an Apple
Silicon hardware launch/exit test. A locally healthy Intel DMG cannot answer any
of those for us. The website source still points at a placeholder download URL,
and replacing that placeholder with this file would turn a test artifact into a
public promise it cannot keep.

So nothing was uploaded. That is not an unfinished copy operation; it is the
release gate doing its job.

### What did land on the Desktop

The verified local candidate was copied without overwriting anything, with its
status made part of the filename:

```text
/Users/lukehightower/Desktop/Buster Claw_0.1.0_x64-UNSIGNED-CANDIDATE.dmg
28,372,344 bytes
SHA-256 98967d62f43a73d1260524a1f310fec70cc7447efaab8a58e02c3820a2631329
```

The Desktop copy and the build artifact have the same digest. It is a useful
local proof built from the current dirty working tree, not the artifact to put
behind the Download button.

> **A DMG existing is a build fact. A DMG being publishable is a chain of
> evidence.** Today produced the first and made the missing links in the second
> explicit.
