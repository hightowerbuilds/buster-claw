# 08-15-26 — Eight guards were green and guarding nothing

Five arcs in one day: a signed DMG that produced four findings in ten minutes,
BusterPhone learning to place a call start to finish, the model finally being
told the truth about what it can do, the macOS Dock icon becoming a Pocket, and
the corner widget becoming a background surface — a five-phase roadmap scoped and
finished in one sitting.

The through-line only became visible near the end, and then it kept happening.
**Eight separate times today, a guard or a switch was green while protecting
nothing** — every one found by deliberately breaking it, never by reading it.
**Four of the eight were mine**, and one was in a contract I wrote for four
agents to build against. The last two were written *in the same hour* as the
section of this summary describing the failure mode.

The seventh guard is the counterweight, and it closed the day: the ACL lockstep
test caught a missing capability on the first run, exactly as its roadmap had
predicted in writing before any code existed.

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
| **`phone_call` — the app can place a bridged call** | `9c1d0b4` |
| **Both kill switches were unflippable; `sms_enabled` had been since 07-18** | `a9f3739` |
| The keypad gets a Call button, and asks once before ringing | `a647409` |
| A bridged call is two bills, and we were pricing one | `d287852` |
| Phase 0: outbound calls present the app's number | `775f9e5` |
| **The model may apply a shader you have looked at once** | `655f7f7` |
| INTRODUCTION.md stopped lying to the model about backgrounds | `ea169ea`, `1a630ec` |
| **The macOS Dock icon is a Pocket** | `6b94a44`, `c0cd5fc`, `701723c` |
| **The corner widget is a background surface** | `f9e6994`, `d34e20d`, `c643efa`, `38bb9a8`, `b900d57` |
| The model's briefing audited against the catalog | `4fedb3d` |
| The 08-13 code review archived, nothing floating | `131448a` |

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

## The phone learned to dial, and A2P had nothing to do with it

The afternoon started with the operator stuck in the Twilio console, which had
classified them as a business. That is **two problems with opposite shapes**, and
reading them as one is what makes the wait indefinite: outgoing *texts* are
blocked by A2P 10DLC registration, which is the operator's paperwork; outgoing
*calls* were blocked by nothing at Twilio and were simply **unbuilt**, which was
ours. A2P is an SMS gate and touches voice in neither direction. So the half that
looked blocked shipped the same day, while the registration is still stuck.

A related question the tab had left implied, and the operator had to ask:
**none of this needs a business.** Twilio sells numbers to individuals, outbound
voice needs no registration at all — only an *upgraded* account, since a trial
dials only verified numbers — and even the SMS side has a Sole Proprietor tier on
a personal tax ID. Now written down, because "do I need a company" is the
question that stops someone using the feature entirely.

**A phase deleted itself.** The roadmap scoped a Supabase edge function serving
`<Dial>` TwiML, with a signature check, a required `PUBLIC_URL_BASE`, and an
opaque id so a public endpoint could not be talked into dialling anything. None
of it was needed: Twilio's Calls API takes a `Twiml` parameter carrying the
document inline. That removed the phase **and its headline risk together** —
there is no endpoint to abuse, and the number dialled cannot arrive from a
callback because nothing calls back.

The design is a **bridge**: your own phone rings first, and `<Dial>` joins the far
end only when you answer. No audio touches the Mac, so calling did not have to
queue behind the unrun WKWebView `getUserMedia` spike still blocking Studio →
Voice. Gated, capped at 5 per recipient per day against SMS's 20, and it reads
the SMS opt-out list — voice has no STOP, and it is the same human.

**Two legs, and we were pricing one.** `<Dial>` creates a second call resource
with its own price, so reading the parent alone reported half the bill *and
marked it settled*. Three things the voicemail path could not lend it: an empty
child list is not `:pending` here (it can mean nobody answered, so one leg is the
whole bill); a price does not imply the call ended; and the work list needed a
give-up, because one row that can never finalize starves every row behind it in
an oldest-first list. That last one **closed the same latent starvation in the
voicemail path**, which had been surviving only by never blocking on the inbound
leg.

---

## The documents that were lying to the model

The evening's thread started as "let the model change the background" and turned
out to be about documentation.

`background_list` / `background_set` had shipped that morning. But
**`INTRODUCTION.md` — the orientation document the model itself reads — said
backgrounds are "chosen in Settings → Appearance" and that the model "can never
force one onto their screen."**

That is the worse version of the bug, not a lesser one. The generated command
table at the end of the same document already listed both verbs. The model had a
table saying *yes* and a paragraph saying *no*, and **prose is what it believes**.
It would have read `background_set` in the catalog and concluded it was for
something else.

Three maps said the same stale thing and were corrected: the image-shader map's
D5 ("the model proposes; the human selects"), `TERMINAL_PAINT`, and
`TERMINAL_THEME`, which cited "Appearance has no commands at all" as a precedent
for refusing something.

> **The pattern is not "docs drift".** It is that a *generated* section and a
> *written* section of the same document can disagree, and the generated one is
> the one nobody re-reads. A guard that asserts "the verb appears in the file"
> cannot see it.

---

## Agent-applied shaders — and where the count started

The operator then asked for the nebula shader on the homepage, got refused, and
said: *"we want you to be able to do that yourself."* A parallel session had
already scoped the fix; the operator clarified the ask — **"we just want the
model to change the background selection, this is separate from the creation of
shader patterns"** — which answered the question the whole design hung on and
inverted the recommendation I had just given. There is no tweak-apply-look loop,
so the friction of approving per version costs nothing.

Shipped: a workspace shader applies by command once the operator has applied its
**exact bytes** themselves. Editing withdraws it. Existing shaders backfilled.
Keyed by content because **names are forgeable** — approving by name would let a
run overwrite an approved file and apply it under a blessed name, the same
file-write shortcut that made "no command authors a shader" insufficient.

Built by **four agents on disjoint files against a contract written first** — the
rule from 08-14, and it held again. What they found:

1. **A built-in shadows a workspace file of the same name**, so minting without
   filtering stored an approval for bytes that can never render.
2. **The store backfills on first read**, so a test that writes a shader and then
   clicks it passes on the day-one grant and never touches the click path. It ate
   a real test.
3. **`approved_shaders/0` — my own contract API — was wrong for the job.** It
   returns the hash that *was* approved, not whether the file still matches, so
   `background_list` would have reported `approved: true` for an edited shader
   that `background_set` then refuses. The agent rejected my suggested API and
   documented the rejection at the call site.

### The six

| # | Looked green | Guarded nothing because |
|---|---|---|
| 1 | `voice_enabled` kill switch | read from a config map `runtime.exs` never wrote — false in every build, and every test set the key directly |
| 2 | `sms_enabled`, same map | gated on an env var that an operator storing credentials in the Clinch does not have. **Broken since 07-18**, and would not have worked when A2P approval arrived |
| 3 | The Call button's disabled state | only its *enabled* behaviour was tested; pinning `disabled` to `false` passed everything |
| 4 | The cost path's terminal-status check | a pending child already covered every case the test exercised — pure scenery |
| 5 | My INTRODUCTION.md guard, v1 | asserted the verb appeared in the document, which the **generated table** makes true; it passed with the whole prose section deleted |
| 6 | My per-built-in loop, v2 of the same guard | `veil` and `weather` occur elsewhere in the section, so it passed with two of the five deleted |
| 7 | My command-family guard for `INTRODUCTION.md` | asserted the verb appeared in the **document**; the generated catalog at the end makes that true, so it passed with the whole prose section deleted |
| 8 | My "the Shaders tab names every surface" guard | asserted against the **page**; the corner widget's own tab button says "Time & Place", so the page satisfied it on the tutorial's behalf |

Five through eight are the ones worth sitting with: **I wrote all four, and the
last two after writing the paragraph above about the first two.** Knowing the
failure mode by name did not stop me producing it twice more the same evening.

The shape is always the same, and it is not carelessness — it is that **the
cheapest true assertion and the correct one look identical in a diff**. "Does
this string appear?" is true for reasons that have nothing to do with what you
meant. The fixes were the same each time: derive the expectation from code
(`Appearance.builtin_shaders/0`, `Appearance.surfaces/0`) and scope it to the
half a human wrote (`String.split` on the generated boundary, `element/2` on the
section id).

There is a seventh that never shipped: nothing proved the four agents' layers
*meet*. Each tested its own half. The handoff — operator clicks here, model
applies there — is now its own test, broken two ways.

---

## The Dock icon, and the guard that worked

The last build of the day, and the counterweight to the table above: **one guard
fired exactly as its roadmap predicted it would.**

Two icons wear that name and only one is touchable. The **bundle** icon is sealed
by `_CodeSignature/CodeResources` — writing it invalidates the Developer ID
signature, the hardened runtime and the notarization ticket at once, so it is
closed, not deferred. The **running Dock tile** is
`NSApplication.applicationIconImage`: set at runtime, reverts on quit, touches no
file. That is exactly what was asked for — your art while you use the app, the
app you downloaded in Finder.

Phase 0 was the operator's, and they picked the middle option: a file in the
Pocket is not an icon; a human applies it. **Implemented by content hash, which
is the same answer the shader question got four hours earlier** — deliberately,
because it is the same question. A "selected" flag names a file, and names are
forgeable: anything that can write the Pocket could swap the bytes under a choice
made about something else.

**The ACL lockstep test caught the missing capability on the first `cargo test`.**
The roadmap had written, before any code existed, that this would be the first
new Tauri command since that guard was added and would therefore be a live check
of whether it works. It works. After a day of guards that did not, that is worth
recording with the same weight as the ones that failed.

Two things the build changed about its own scope:

**The proposed Dock badge was not built, and the reason is better than the
proposal.** A fourth state appeared that the scope had not imagined —
*applied, then the file changed* — and it looks exactly like a bug from outside:
the custom icon is gone, the file is still on disk, nothing was clicked. The
panel has to explain that in words regardless, and once that sentence exists the
over-full case is one more sentence beside it. A badge would have split the
explanation across two places, one of which cannot hold sentences. The copy names
who could have replaced the file — *"including the agent"* — and a test asserts
that phrase.

**It shipped without an upload button and the operator hit it in the first
minute.** The Pocket was fillable only from Finder, which is not how anything
else in that panel works. Fixed by making the file picker a shared component
rather than a second copy: its four failure states now render once, and that
file's own comment records what happened the last time they were missing — a
*refused* file looked identical to a file nobody had chosen, so the upload read
as doing nothing.

> **And one overstatement of my own, corrected.** I filed the verification walk
> as needing a packaged DMG. It does not: `./scripts/dev.sh` opens the real Tauri
> window, and a Tauri app in dev has a real Dock tile. Only the Finder step —
> quit, confirm the installed icon is untouched — needs the signed bundle. **A
> check described as "needs a DMG" gets deferred; this one is two minutes**, and
> it is the one that would catch the threading assumption being wrong.

---

## The corner widget, scoped and finished in one sitting

The last arc, and the one that shows what a map is worth. The widget's Time &
Place card already rendered a shader — `daycycle`, hardcoded — it just rendered
one nobody could change. Making it selectable looked like deleting an attribute.
Writing the map first turned up two things that would have made it an afternoon
of confusion instead:

**`home_widget.ex` was 699 lines and FROZEN** — the gate tier meaning *no
headroom by definition*. So Phase 0 was a decomposition standing in front of a
small feature, and it was done **on its own with no feature attached**: a split
and a behaviour change in one commit is how you lose track of which broke what.
699 → 135, three panels as siblings. The extracted text was diffed against the
original line ranges and is byte-identical apart from `defp` → `def`.

**`u.lens` already had two owners** — `data-daylight` feeds it a clock fraction
for `daycycle`; the `weather` shader overwrites it with real sky. They coexisted
only because the widget never selected weather and nothing else selected
daycycle. Both assumptions die the moment the shader is a choice, so the flag had
to become a property of the **shader** rather than the mount. Otherwise picking
daycycle on the homepage gives a sun frozen at midnight, with nothing reporting
it.

Three findings the build added to the map:

1. **The card never `:if`s its tabs.** It renders all three and hides two with a
   class, so the Time & Place canvas is mounted and animating whichever tab you
   are looking at. That is the opposite of `PhoneComponent`, whose moduledoc says
   it `:if`s *precisely* so `phx-update="ignore"` canvases are torn down instead
   of animating unseen. Two surfaces, same app, opposite answers.
2. **One list was doing two jobs.** `@builtin_shaders` answered both "is this
   bundled in the JS?" and "is this offered?" — the same set right up until a
   default has to be renderable *without* being selectable, which is what the
   operator's D2 asked for. Without splitting them, the card renders blank with
   no error anywhere.
3. **The density bug was the label, not the buttons.** Flex children do not
   shrink below their content, so a long option name pushed the buttons out of
   the row instead of ellipsing — invisible with two surfaces, reachable with
   three.

`default` became a mode on every surface as a side effect: it is the only way
back to a sky nothing can select by name, and **the first honest undo any surface
has had.** Before it, "put it back how it was" meant knowing what it was.

> **The model needed no code at all**, which is the map's best moment.
> `background_set` reached the new surface because `fetch_surface/1` validates
> against `Appearance.surfaces/0` — a claim `Catalog.Appearance` had been making
> since before a third surface existed. But testing the model's path found a bug
> the operator's path could not: `default` was reserved in `Appearance`, and the
> command layer runs its own gate **in front**, so an unapproved
> `shaders/default.wgsl` made the one undo every surface has *refuse*.
> **Reserving a word in one layer does not reserve it in the layer above.**

---

## The briefing the model reads, audited against the catalog

Prompted by the widget adding a third surface to a document that said two — and
then done properly, by grouping all 206 commands by family and diffing against
the prose rather than reading it.

**Twelve families the briefing never mentioned. Seventy-three commands.** The
largest was `sound_*` at 29, which includes `sound_record` — the one verb in this
app that opens the microphone. A model with a generated table and no orientation
either does not reach for a capability or misuses it, and "opens the microphone"
is the wrong one to leave to inference.

Two guards, because these fail differently. One asserts every command **family**
is named in the half a human wrote, so a thirteenth turns the briefing red. It
catches absence and provably cannot catch a **denial** — `phone_*` was named
throughout while a bullet said outbound calling did not exist — so a second ties
the phone claim to `phone_call` being in the catalog.

Also archived: the 08-13 whole-codebase review, once its content was verified to
live in the four leftovers maps. Sweeping every relative link under
`daily-growth` afterwards found **two more I had broken that morning** archiving
the DMG review. Nothing checks for that, and archiving is when it happens.

---

## Where this leaves the build

The review is **closed and archived**, with one thing deliberately moved rather
than ticked: findings 1 and 2 are proven **in dev only**. The packaged re-check
is in `QA_BACKLOG`, because a replay of launchd's environment is not the same as
launchd. Two tails — a synchronous `installed/0` in a mount, and no way to
re-check a harness list — are in `LEFTOVERS_PLATFORM`.

Still nobody has opened this app on a machine that did not build it.

`OUTBOUND_VOICE_ROADMAP` and `AGENT_APPLIED_SHADERS_ROADMAP` are both
**complete — nothing in either is open.** Which leaves the money leg in an odd
shape worth saying plainly: BusterPhone can receive calls, receive texts and
**place calls**, and the only thing it cannot do is send a text. That is the one
gate that was never ours.

**To place the first real call:** upgrade the Twilio account out of trial, set
`TWILIO_PHONE_NUMBER`, `OPERATOR_PHONE_NUMBER` and `BUSTER_CLAW_VOICE_ENABLED`,
restart, press the button.

**Built, and unwalked in one specific place:** the macOS Dock icon. Every layer
is tested except the one that talks to macOS — there is no Dock in `mix test` and
none in a browser. The walk is two minutes in `./scripts/dev.sh` and is filed in
`QA_BACKLOG` with the three things it would prove.

**Owed:** the mode grammar is now parsed in three places, two of them written an
hour apart by agents who could not see each other, and they already differ. Filed
in `LEFTOVERS_SURFACES` with both cap raises naming it inline, so the debt is
visible from the gate. `appearance_live.ex` is at 1,064 lines against a cap
raised three times today, which makes that extraction the most overdue thing in
the repo.

Still nobody has opened this app on a machine that did not build it.

**Gates at close:** precommit exit 0 — 4,083 tests, credo clean, 2 accepted
cycles, file-size inventory holds, 322 bun and 46 Rust tests green.
