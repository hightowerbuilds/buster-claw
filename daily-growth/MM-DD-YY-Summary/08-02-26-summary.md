# 08-02-26

## The calendar's form stops living at the bottom of the tab

The manual date/event form was pinned under the month grid — always rendered,
mostly ignored, and a long reach from the month it describes. It is a modal now,
opened by an **Add Events** button riding inline with the month/week/day toggle.

Two things fell out of the move for free. Clicking a day cell was *already* the
"add something on this date" gesture, but it only silently prefilled a form
sixty percent of the way down the page; it now opens the modal with that date
filled in, so the gesture finishes what it starts. And Edit from an event's
inspect panel opens the same modal in edit mode, which means one form serves
create and edit instead of two surfaces drifting apart.

The form itself is unchanged — Repeat plus Repeat-until is what makes an event
recurring, so one simple form still covers single and recurring without a mode
to pick. House modal idiom throughout (backdrop, ×, Cancel, Escape); saving and
deleting close it; an abandoned draft resets so the next open starts clean.

All three calendar surfaces got it at once — `/calendar`, the split pane, and
the homepage sub-tab — because they have always shared one component.

## The workspace roadmap closes the file

Scoped, built, verified, and archived inside about eighteen hours. The document
moved to `archive/08-01-26-workspace-review-roadmap.md`, keeping its scoped date
— the archive is organized by when a thing was undertaken, not filed.

**Before archiving, the guard suite was re-run rather than the document
trusted:** 24 workspace tests green, and the registry's declared names checked
on disk (`jobs`, `backgrounds`, `Dispatch.md`, `.buster-claw`). No overnight
drift. A roadmap that says COMPLETE is a claim; the suite is the evidence.

**The number it was judged by, restated because it is the whole point:** a fresh
packaged install lays down **seven visible entries, every one holding content**,
down from sixteen of which seven held nothing.

**One item outlived it** and moved to `roadmaps/LEFTOVERS.md`: repeat the
first-open look through the **setup wizard + Finder**. The verification walk set
the workspace by env var, so the scaffolding is proven and the wizard's path
into it is not — plus how the folder *reads* to a human, which no test asserts.
It joins the two other packaged-build walks already parked there: one build,
three answers, folded into the R1 QA pass.

**Two archive hygiene notes.** Yesterday's summary carried two now-stale
`roadmaps/…` paths, repointed to the archive. Its mid-day "the workspace rebuild
is 3 phases of 5" passage was left standing with a note rather than rewritten —
what the remaining work looked like from the middle of the day is the record,
and editing it to match the outcome would be tidying away the honest version.

`roadmaps/` now holds four live documents: `LAUNCH_ROADMAP`, `SOUND_STUDIO`,
`TRADING_TAB_CRITICAL_REVIEW`, and `phone-maps/BUSTERPHONE`, plus `LEFTOVERS`.
*(By the end of the day: still four — the browser gained one and the Sound
Studio was archived. See both below.)*

## Agent Mode was a one-way door

Read the 07-25 browser field test again and found the defect it described
without naming. Its last line of telemetry — *"Final mode: `stopped` — not
`done`"* — was filed as a consequence of Finding 2. It was its own bug.

`AgentMode.complete/1` exists, and `Mode` has always allowed
`agent_working → done`. It had **one caller in the codebase**:
`Commerce.confirm_purchase`, which needs `awaiting_human`, a non-empty cart, and
the GUI form. So a non-commerce run — research, a price check, a form fill — had
no path to `done` at all. It sat in `agent_working` indefinitely, holding a
leased Chromium window open and the browse tab pinned in Agent Mode, until
someone stopped it, and then went into the record as halted. Every successful
errand ended as a lie.

Two things compounded it. The command surface had no `resume`, so the payment
handoff was a one-way door: `agent_working` is the only mode that acts, and the
GUI had a Resume button the API didn't. And the banner took the newest
registered run unconditionally while runs *stay* registered after they end
(the trajectory is the receipt) — so one dead run pinned the tab with every
control hidden, since they all render only while the run is live.

Three fixes, one per surface: `agent_run_finish`, `agent_run_resume`, and a
banner where a live run outranks a terminal one, terminal runs can be dismissed,
and `awaiting_human` gets the human's own **Done** — a transition `Mode` always
allowed and nothing ever called. The introduction now says every run you start
you must end, and that stop and finish are not interchangeable; a verb the model
doesn't know about would not have fixed anything.

## A roadmap for the question underneath it

`BROWSER_CLOSEOUT_ROADMAP.md` — small, and mostly one question: **may the agent
confirm a purchase?** The field test asked for `agent_run_confirm_purchase`; we
did the opposite in passing and told the model it may never confirm. That call
deserves to be made deliberately, and two things have changed since. The
stuck-run fix removed the pressure — a commerce run can now be marked `done` with
no capture and no receipt, and nothing complains. And the ledger the receipt was
meant to reach **no longer exists**: the wallets subsystem was deleted in
`db10a58`, so confirming today writes a PNG and returns a map.

So it is really two questions, in order: *what should a confirmation produce* (a
durable greppable record in the workspace is the recommendation — not a rebuilt
ledger), and *who may make one* (agent proposes, human attests). Four mechanical
items came along from `LEFTOVERS` so they stop living in a file whose own rule
says a thing needing a design does not belong there.

## The Sound Studio ships as two-thirds of what it set out to be

Archived to `archive/07-30-26-sound-studio-roadmap.md`. Four days of build, and
the honest header says what shipped and what did not, because the 07-30 scoping
locked **three halves** and only two got built.

**Built:** the pure editing core — splice, fade, normalize, mixdown, WAV
parse/render — plus the Studio as a Home sub-tab, drag-to-trim on the waveform,
the multi-lane arranger, copy/paste/undo, track identity and colour, a transport
that performs the timeline, `afconvert` import, and right-click delete.

**Not built:** the `sound` CLI verbs (Phase 2) and the chime designer (Phase 4).
So the Studio is a cutting-and-arranging tool: you can take a voicemail apart and
lay it out, but you cannot *tune a chime*, and **no agent can reach any of it**.

Both went to `LEFTOVERS` rather than dying with the document, with a note that
the designer is the largest unbuilt thing in that file and should be **promoted
back to its own roadmap** if it is genuinely wanted — picking up a third of a
locked scope from a leftover line is how it would get done badly.

Phase 5's remainder folded into the byte-range walk already parked there: the
packaged webview's autoplay posture and seeking a long track. Its harder half —
does `afconvert` run inside the sandbox — was answered yes on 08-01.

## …and then we kept building on it, which is the point of archiving honestly

Archiving a roadmap closes a plan, not the code. Three studio changes landed
after the file was archived, and none of them wanted a roadmap.

**The sidebar's right-click menu was opening near the middle of the window.**
The cause is worth writing down because it will recur: `.ic-home .ic-panel`
carries `backdrop-filter: blur(10px)` — the frosted treatment the smoke shader
reads through — and **`backdrop-filter` makes an element a containing block for
`position: fixed` descendants**. So the menu's viewport coordinates were being
resolved against the Studio panel's box instead of the window. Rather than
hardcode "subtract the panel", which breaks the moment a transform appears
anywhere in the tree, the hook now parks itself at 0,0, measures where that
actually lands, and works from the delta — correct whichever ancestor wins. It
anchors to the row now: top-aligned, just off the right edge, flipping left at
the window edge and closing on scroll rather than pointing at the wrong file.

**Two verbs joined Delete.** *Info* — a modal with the path on disk (rendered
`select-all`, since the path is the useful part), size, length and format, all
from the `afinfo` header probe so a 40-minute recording answers as fast as a
chime. *Add to new mix* — one gesture: a new arrangement named after the source,
the source already on its first track, opened. What appears is decided
server-side per row, so an arrangement (a list of references, not audio) offers
only Delete, and a built-in chime is the mirror case.

## "Audio" was doing two jobs, so the arrangement became a mix

An imported `.wav` is audio too, which made "add this audio to that audio" a
sentence the UI could not say. A **mix** holds **tracks**, each holding
**clips** — one word per thing. `StudioAudio` → `StudioMix`, the `:audio` kind
and `"audio:"` ids with it, and **Add clip moved to the top** of the mix panel,
because it is how a mix starts and everything below it is the result of using
it. *Import audio* kept its name: that one really is audio.

**The disk format moved too, reversing 08-01's call.** v1 said `tracks/`,
`.track.json`, `"lanes"` — the words of the *first* naming — and was left alone
in the previous rename on the grounds that these files are hand-editable and may
already exist. A second rename changed the calculus: the cost was no longer one
stale word but **three vocabularies in one system** (disk saying lanes, code
saying tracks, UI saying mix), which is how a hand-editable format stops being
hand-editable. So v2 is `mixes/.mix.json/"tracks"`, and the original promise is
kept a different way — `migrate_v1/0` folds the old directory in with the house
merge-don't-clobber posture, `from_map/2` reads `"lanes"` forever, and the next
save rewrites as v2. Nothing is orphaned.

## The rename killed the right-click menu, and the suite did not notice

The sweep covered the `.ex` files and not the JavaScript. It renamed
`data-ctx-new-audio` to `data-ctx-new-mix` in the markup while the hook kept
querying the old name — `querySelector` returned null, and the TypeError thrown
in `mounted()` took down the **whole hook**, `contextmenu` listener included. Not
one broken item: no menu at all.

**The suite stayed green through it**, because every menu test drives the server
half via `render_hook`, which fabricates the event and never touches the JS. The
markup-to-JS contract had no test, so a rename could sever it silently.

Guarded two ways. The hook degrades now — a missing node becomes an inert
stand-in, so the next mismatch costs one item rather than the feature. And a
lockstep test reads the hook and asserts every `data-ctx` selector it queries
exists in the rendered markup, and every event it pushes has a `handle_event` on
the component — the same idiom as the workspace registry guard. Verified by
breaking it on purpose; it fails naming the offending selector.

**Worth recording plainly:** the operator caught this, not the tests, and it is
the second JS/server boundary to slip through in two days (the `phx-target`
crash was the other, though that one at least failed loudly). Anything changed
by sweep deserves a look in the real app before it is called done.

## Rename, and the things that have to move with a file

Rename joined the right-click menu on the same permission as delete: it is your
file or it isn't. The menu becomes the field in place, Finder-style — Enter
commits, Escape abandons, and commit is on **keydown rather than blur**, because
renaming on a stray click somewhere else is a destructive thing to do by
accident. No `prompt()`, for the same reason there is no `confirm()`: it would
block the webview's event loop.

**The interesting half is not the rename, it is everything pointing at the
file.** A mix clip stores a catalog id (`"import:cut.wav"`), never a path —
which is exactly what lets a mix survive its sources being re-edited, and
exactly what a rename could orphan. So `StudioMix.retarget/2` repoints every
clip across every saved mix and the note says how many followed;
`Sound.rename/2` repoints event routing the way `delete/1` prunes it, because a
rename must not silently unhook a notification; and a mix's name — which lives
in the filename *and* inside the file — moves in both places.

One consequence is the point rather than a side effect: workspace sounds
override bundled chimes **by basename**, so renaming your `confirm.wav` to
`doorbell.wav` stops it overriding confirm and the built-in comes back. Pinned
by test, because it will read as a bug to whoever meets it first.

**Two guardrails the existing code taught us.** The extension is never the
user's to change — typing `sneaky.txt` over a `.wav` yields `sneaky.wav` — so a
rename cannot change what kind of file something is. And the emptiness check has
to be on the **request**, not the sanitized result: `Music.safe_name/1`
substitutes `"track"` for anything that reduces to nothing, so a check on its
output can never fire. `StudioMix.safe_mix_name/1` documents that exact trap in
a comment, and the test caught this session walking into it anyway.

## The sidebar folds, and remembers

Five groups down the left and usually one of them matters. Each heading is the
hinge — the whole width, not a caret — with a rotating marker and a count that
stays visible, because collapsed, the count *is* the summary: "Music 47".

**Where the state lives was the only real decision.** Part V landmine 2: the
Home sub-tab renders behind an `:if`, which REMOVES the component and everything
it owns. So the collapsed set sits in `StatusLive` beside the selection, the
trim, and the undo stacks — a sidebar that re-expands on every glance at Chat is
not collapsible, it is briefly tidy. Then it is persisted to Settings as well,
because one that re-expands on restart is a preference the app keeps forgetting.
There is a test for each: switch tabs and come back, and mount fresh.

Three smaller calls, each borrowed from something that solved the problem first:

- The stored state is the **collapsed** set, so a group added later starts open
  and this code never needs the full roster.
- The list is **filtered against the roster on read** — `Sound.sound_map/0`'s
  posture — so a group we stop shipping cannot leave a key behind forever, and a
  hand-edited settings row cannot introduce one. An empty set deletes the row
  rather than storing `"[]"`.
- A folded group renders **no rows at all** rather than hiding them with CSS.
  The rows carry the right-click menu's data attributes, and a hidden row is
  still a row the menu could open for a file you cannot see.

`group_keys/0` is new and deliberately cheap, because `groups/0` reads four
directories and the telephony table — far too much work to answer "is this a
real group?". A lockstep test asserts the two agree, since they are two
statements of one fact.

At close: 2,139 tests green, credo strict clean, everything on `main`.

## A rendered mix can become a notification without leaving the Studio

Rendering is the moment a mix stops being an arrangement and becomes a sound,
which is exactly when *"and what is it for?"* is worth asking — ask later and you
never ask. So Render now opens a small modal: pick a notification, or **Not
now**, which is a real answer since the render is saved either way.

Assigning does two things, and both are the point. The file is copied out of
`sounds/studio/` (working material) into `sounds/` (what the app plays
unattended) — the roadmap always described that as *"the deliberate step"*, and
this is it. Then the key is pointed at the file **by name**, not installed as
`alarm.wav`: this layer overrides bundled chimes by basename, so the second
would silently replace the built-in alarm for good and un-assigning could not
bring it back. Settings → Notify can still change its mind about any of it.

Two things were missing underneath and are now real API. `Sound.install_file/2`
— the door between the two folders, never overwriting, telling the caller the
name it actually got. And `Sound.route_options/0` + `route_label/1`: the labels
for the seventeen routing keys used to live inside `NotifySettingsLive`, and now
that two surfaces offer routing, a label defined twice is a label that drifts.
The settings screen keeps its richer rows (group, and the kind/source a Test
fire needs) and derives its labels from `Sound`.

## Renders land in the library, and a latent crasher fell out of it

A rendered mix now writes to `sounds/` — the folder Settings → Notify lists —
rather than `sounds/studio/`. That is the whole ask: a mix becomes a choosable
notification sound with no export step and no second gesture. It also settles
which folder a render belongs in, and the answer was always the library:
`studio/` is what you are working ON, `sounds/` is what the app will play.
Nothing is lost by not keeping a studio/ copy, because library sounds are
addable as clips — a render can still be a layer in the next mix. The assign
modal shrank accordingly: the file is already there, so it only routes.

**Then the suite started failing intermittently, and it was worth chasing.**
`mix test` passed; `mix precommit` failed with 76 failures, then 467. Stashing
the change made it green, which pointed the finger at the change — wrongly, as
it turned out. Running the suite in a loop and reading the *first* failure
rather than the count found the real thing:

    [error] GenServer BusterClaw.RateLimiter terminating
    ** (ArgumentError) :erlang.send_after(nil, #PID<...>, :sweep)

`RateLimiterTest`'s teardown restored each config key by writing back whatever
it read at setup — and three of those four keys are **not set in
`config/test.exs`**, so it read `nil` and wrote `nil` back. `get_env/3`'s
default does not apply to a key explicitly set to nil, so from that moment
`window_ms()` was nil. The supervised sweeper then raised on its next tick,
restarted, raised again, and its supervisor gave up — **taking the Repo with
it**, which is why hundreds of unrelated tests failed with "could not lookup
Ecto repo". Intermittent because it needed the sweep timer to fire inside the
same run; my change was only slow enough to make that likely.

Fixed at both ends. The teardown now **deletes** keys that were absent instead
of writing nil. And `window_ms/0` treats nil as absent, because this process is
supervised and no config mistake should be able to take the application down —
with a test that sends `:sweep` with a nil window and asserts the same pid is
still alive afterwards. Five consecutive suite runs and two precommits green.

**The lesson worth keeping:** a failure count is not a diagnosis. Reading the
first failure and what logged just before it found in minutes what stash-and-
bisect was actively pointing away from.

---

## At close

**Suite: 2,143 tests, 0 failures**, credo strict clean, Rust 29 + 5 lockstep
green — verified across five consecutive runs and two precommits, because the
day ended on an intermittent failure and one green run would not have meant
anything.

**Two roadmaps archived, one written.** `roadmaps/` now holds four live
documents — `LAUNCH_ROADMAP`, `BROWSER_CLOSEOUT_ROADMAP`,
`TRADING_TAB_CRITICAL_REVIEW_ROADMAP`, `phone-maps/BUSTERPHONE_ROADMAP` — plus
`LEFTOVERS`, which grew by four browser items and the Sound Studio's two unbuilt
phases, and shrank by none.

**The one decision waiting on the operator** is `BROWSER_CLOSEOUT_ROADMAP`
Part I: may the agent confirm a purchase, and what should a confirmation even
produce now that the wallets ledger is deleted? Everything else in flight is
work, not a question.

**Three things caught by looking rather than by testing**, worth naming together
because they are the same lesson: the right-click menu that a rename killed
silently, the header-probe bug found by importing a real 20-minute file, and the
RateLimiter crasher that a failure *count* actively pointed away from. The suite
is 2,143 tests strong and none of the three was its idea.
