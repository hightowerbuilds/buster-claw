# 08-09-26 — Three looks for the chat, three for the terminal

**Two roadmaps scoped and closed, both in the Settings → Appearance tab.**

| Shipped | Commits |
|---|---|
| Chat skins — 3 looks for the homepage chat, live | `6458a32` `a89f6b7` `064d6b2` `040d648` |
| Chat text size — a second, independent axis | `8d7213e` |
| Both new skins keep the homepage's blurred panel (operator correction) | `3e4c632` |
| Chat theme moved into the gap under Theme | `39f7323` |
| Terminal themes — Elixir owns the list, then 3 presets | `d0d1363` |
| A custom terminal palette, generated from a spectrum | `8634308` `876a7f4` |

**One thread runs through all of it:** every one of these settings had to apply to
things *already on screen* — messages already in a stream, terminals already open —
which is what pushed both features into CSS-and-attributes rather than re-rendering,
and what made "half-applied" the failure mode worth designing against in each case.

**Two operator corrections landed the same day they were caused**, and both were
cases of matching a reference instead of matching this app: the opaque panels, and
copying a preset where a spectrum was wanted. Both are recorded with the reasoning
rather than just the fix.

---

Scoped `CHAT_SKINS_ROADMAP.md` and shipped all four phases: the homepage chat now
has three skins — **Industrial Claw** (as it was), **Minimal** (a terminal
transcript), **Workplace** (avatar, author line, hoverable rows) — chosen from a
dropdown in Settings → Appearance, applying the moment you pick it.

`6458a32` the setting and the wire · `a89f6b7` the markup anchors · `064d6b2` the
three skins in CSS · `040d648` the dropdown and the preview. Then a second ask the
same day: **a text size**, four steps from 100% to 150%, as an independent axis.

## The finding that wrote the design

The obvious build is to branch the bubble's class list on the current skin. It
produces the worst available bug, and only on a chat that already has messages in
it.

The transcript is a **LiveView stream**. Stream children are rendered once, on
insert; a later parent re-render sends no stream ops, so a message already on
screen keeps the DOM and the classes it was born with. Switch skins and the
header and composer change while the ten messages above them stay in the old
look, until a reload. **It would have demoed perfectly on an empty chat.**

The only other way out was to re-stream on every switch, which needs a list
assign duplicating a stream that is deliberately capped and stream-only. So:

> The rendered DOM is identical under all three skins. The server varies exactly
> one thing — `data-chat-skin` on the panel's root section — and every visual
> difference is a CSS descendant rule.

That is not a style preference. It is what keeps the feature from being
half-applied, and it is cheap to assert: render the panel three times, normalize
the attribute away, demand byte equality. A future `if @skin == "slack"` in the
template fails on the spot. An element one skin needs is rendered by all three and
hidden in the others.

## Why it works without a single !important

The document originally justified this by specificity — two-selector rules beating
single-class utilities. That reasoning is true but not the mechanism. Hand-written
rules in `app.css` are **unlayered**; Tailwind's utilities live in
`@layer utilities`; unlayered CSS beats layered CSS outright, whatever the
specificity. Checked against the built `priv/static/assets/css/app.css` rather
than asserted, and the roadmap was corrected. Specificity still decides against
the *other* unlayered `.ic-*` rules in the file, which is why beating
`.ic-home .ic-panel` takes three selectors.

## Content in the DOM, decoration in CSS

Two elements no skin renders today but one skin needs had to land somewhere, and
they split on a rule worth keeping:

- **The author name is content**, so it is a real `sr-only` span. Consequence
  nobody asked for and everybody gets: it is announced by a screen reader in
  **every** skin, where alignment and colour never were. It also survives
  copy-paste.
- **Minimal's `>` sigil is decoration**, so it is a `::before` and appears nowhere
  in the markup. A screen reader should not read a glyph aloud, and it should not
  land in copied text.

`sr-only` being `position: absolute` is also why adding the author line moved
nothing: out of flow, so the parent's `gap` never saw it.

## Three defects, all the same shape

Every one was a rule that was correct for the *look* and wrong for the *panel*:

1. `gap: 0` on every `[data-chat-role]` would have crushed the tool line's icon
   against its text — that row is a flex row, not a stack.
2. Workplace's avatar-less rows (tool, meta, error) would not have lined up with
   the rows that have one, because the log gave up its horizontal padding so each
   row could own it.
3. Zeroing the textarea's border **silently removed the focus indicator** in both
   new skins: `focus:border-primary` cannot colour a 0-width border. Minimal now
   focuses a left prompt bar, Workplace focuses the box.

The third is the one to remember. **A skin can delete an accessibility affordance
while looking finished**, and nothing in the suite would have said so. Which is
why the CSS gate now also asserts no skin sets `display: none` on anything — a
control may be restyled, never removed.

## A stylesheet nothing had ever asserted

`ChatSkinCssTest` reads `app.css` and holds five things: every non-default skin
has rules; **the default skin has none** (its baseline is the utilities in the
markup, so an empty block is proof it cannot regress through this file); no hex
literals, because three skins against dark and light is six combinations and a
literal can only be right in one; no `display: none`; and every `data-chat-*`
selector in the stylesheet exists in `ChatPanel`, so no rule is dead. Its pair in
`ChatPanelTest` names the anchors from the other side.

## The preview is the feature, not a garnish

"See it immediately" cannot mean the homepage — the operator is on the settings
page. So Appearance renders a live transcript preview that restyles in the same
round-trip, and it renders the **same private `chat_bubble/1`** the live chat
does, in the same container (extracted to `log_class/0`). A second copy of the
bubble markup would drift within a month, and this is the single surface where a
drift would go unnoticed, because it is where you go to check.

It did **not** need the public bubble API the roadmap assumed: putting
`transcript_preview/1` inside `ChatPanel` lets it call the private clause
directly.

Two omissions are stated in the UI rather than implied — the composer is not
previewed (a form with live hooks and a `chat_send` submit that would crash the
page), and neither is the panel chrome (those rules describe a panel over the
homepage's shader, which no settings page has). Both are real gaps, and an
unlabelled preview is exactly the quiet promise this app keeps having to un-learn.

## The text size, and why it is a second axis

Four steps (Normal / Large / Larger / Largest — 100 / 115 / 130 / 150%) in a
`ChatTextSize` module mirroring `ChatSkin`, with its own key, topic and dropdown,
sharing the same preview. **Two axes rather than twelve skins:** wanting larger
text must not cost you the look you chose. They multiply — every font-size in the
chat is `calc(<its own size> * var(--chat-scale, 1))` and the setting supplies the
one number.

`normal` is scale 1 and therefore writes **no CSS at all**, because the `var()`
fallback already means "as designed". Same argument as the empty `industrial`
block, and same payoff: the shipped reading size cannot regress through the
stylesheet.

**The type sizes had to leave the markup.** `text-[17px]` and four siblings *were*
the chat's type scale, and a utility class cannot be multiplied. So they became
`calc()` expressions in `app.css`, which narrows the Phase 2 claim honestly: the
*skin* block is still empty, but the type scale is now shared and lives in CSS. A
test refuses a `text-[17px]` coming back, because a bubble that pinned its own size
would sit still while everything around it grew.

Scaled: the things a reader reads — bodies, tool lines, run notes, composer, empty
state, Workplace's author line. **Not** scaled: buttons, chips, labels. The ask was
readable text, not a magnified UI, and scaling chrome is how an interface starts
clipping.

The one number lives in two places (the module's `scale`, the stylesheet's
`--chat-scale`) and cannot drift: the CSS test reads the scales out of the module
and requires each to appear in `app.css`. A UI promising 130% while CSS applies
1.15 fails the suite.

`status_live.ex` sat one line under its cap and both axes cost it exactly one more,
because `status/chat.ex` absorbed the wiring — `subscribe_chat_look/0`,
`assign_chat_look/1`, and a single `handle_info` clause guarded on
`axis in [:chat_skin, :chat_text_size]`, where the axis name *is* the assign name.
That is the shape the size gate exists to produce rather than to punish.

## The opaque draft, corrected the same day

Both new skins shipped **opaque**, on the reasoning that a vim window should look
like a vim window and a workplace app should feel solid. The operator caught it
within the hour: every panel on the homepage is translucent with a backdrop blur
(`.ic-home .ic-panel`) so the live shader reads through, and a solid chat was the
only solid panel on the page — it read as a bug, not a look.

Both now leave `background` and `backdrop-filter` alone and change only the frame's
geometry: Minimal a hairline square border with no offset shadow, Workplace a
rounded hairline with a diffuse one. Workplace's composer box went from
`base-100` to a 55% tint for the same reason — a solid box inside a blurred panel
is the same mistake one level down.

**The lesson is about which master a skin serves.** "Slack is opaque" and "vim is
opaque" are both true and both irrelevant: a skin lives inside *this* app's surface
treatment, and matching the reference beat matching ourselves. The roadmap had even
licensed it — it said translucency was "each skin's call" — so the document was
wrong before the CSS was, and it now says the opposite with the reason attached.

## The gap under Theme, and a grid trap

Chat theme shipped full-width below everything, which left an empty half-column
under **Theme** while the terminal palette filled the right side. Moved into that
gap, and compacted for it: the two dropdowns share a row, the copy is one line
each, the preview takes the width it is given (a transcript is narrow anyway).

**The obvious move is wrong.** Making Chat theme a third child of the two-column
grid puts it in column 1 **row 2** — below the tall terminal column's baseline —
so the gap survives while the markup looks correct. The left cell has to become a
stack containing both panels. A test asserts document order (chat heading before
"Terminal theme") precisely because that is the mistake a future refactor would
make while looking right.

## Cuts, taken as decisions

- **No smaller sizes.** Nobody asked to shrink the chat, and Minimal already runs
  the tightest type in the app. A "Small" step is one line if it is ever wanted.
- **No timestamps.** Workplace wants a clock and there is none to show: the
  message map has no `at`, and history is rebuilt from stored rows, so old
  messages would get a blank column or an invented time. Cut, with the revisit
  starting from "do the stored rows have a usable stamp."
- **No avatars from real identity** — Workplace's is a coloured square in CSS.
- **No other surface.** `chat_panel` has one call site, which is what kept this
  small.
- **No operator-authored skins.** That is arbitrary CSS in the app shell — a
  security question, not a styling one. Note the precedent next door: Appearance
  accepts arbitrary user `.wgsl` and has **no commands at all**, because only a
  human click may put user GPU code on screen. A CSS-skin feature owes the same
  argument first.

## Housekeeping

`chat_panel.ex` crossed 1,000 lines and entered the file-size inventory at
**1,020** — the first number anyone has put on it, set where the skins left it,
with the next cut named in the same comment (the bubble family is a coherent
module hiding inside a panel module). The acceptance walk went to `LAUNCH_ROADMAP`
**G-40**, since it is a build and a person looking: six skin/theme combinations,
four controls, and the one claim CI cannot make — whether it reads well.

Also worth recording: another session held `pockets.ex` in a warning state and ran
the suite concurrently for much of the afternoon. `MIX_TEST_PARTITION=skins` gave
this work its own SQLite lane, which is the difference between "30 failures" and
"Database busy."


---

# Terminal themes — one list, three presets, and a palette of your own

`TERMINAL_THEME_ROADMAP.md`, all three phases (`d0d1363` + the editor). The ask was
a UI for custom colours and then a cull to Industrial / Nord / Monokai.

## Two things that were not what they looked like

**A theme is 21 colours, not three.** The picker's swatch shows background,
foreground and accent, which is why this reads as a simple feature. An xterm palette
is five core values plus **8 ANSI colours and 8 bright variants** — and those 16 are
what colour `ls` and `git status`.

**The list already existed twice.** The palettes were in `assets/js/lib/theme.js`;
a second, partial copy (key, label, three swatch colours) was in `AppearanceLive`,
kept in step by a **comment** and nothing else, with **no test touching terminal
themes at all**. Which makes the cull precisely the shape this repo keeps getting
bitten by: delete from one language and the suite stays green either way, leaving
either a dead palette or a swatch that selects a theme which no longer exists and
silently renders the default.

So the cull came *second*. `BusterClaw.TerminalTheme` owns the list, `theme.js`
applies it, the payload arrives as `<meta name="bc-term-palettes">` — in the head
rather than on the picker, because a terminal can mount on a page that has no
picker. A `<meta>` rather than a JSON `<script>` block because the CSP here is
`script-src 'self'` with nothing inline: a data block is not executed and so not
actually blocked, but the repo deliberately removed its last inline script to drop
the nonce, and re-adding a tag that merely *looks* like a violation buys nothing.

**Industrial stays a `null` palette, meaning token-derived.** It is resolved in the
browser from `--color-base-*` and `--color-primary`, which is what makes it the only
theme that follows the app's light/dark switch. Elixir cannot read computed CSS, so
it declares the fact and leaves the resolving where it has to happen. Flattening
every theme into fixed hex would have killed that on the **default** theme — the
kind of regression nobody files, they just notice the terminal stopped matching the
app.

## The custom theme is generated from a spectrum

*(Shipped first as a copy of a preset; revised the same day on the operator's
call.)*

The entry point is a **hue slider whose track is the hue wheel**: one number in, all
21 colours out. What carried over from the copy version is the reason it existed —
the palette is **always complete**, so a custom theme can never be the half-applied
thing where the background is yours and `ls` is xterm's. What got better is that
every position on the track is a theme, instead of a choice between two names.

**The hue tints the surfaces fully and pulls the sixteen program colours only 15%
toward it.** That is the rule the whole scheme hangs on: a spectrum that slid `red`
round to green would produce a theme that *lies*, because red means error output in
every program ever written. So the eight keep their canonical hues and take cohesion
from shared saturation and lightness. A test walks six hues around the wheel and
asserts red's dominant channel is still red.

Generation is **deterministic**, which is what lets the slider be dragged back and
forth rather than being a one-shot roll, and **dark by construction** — a light
scheme inverts the lightnesses and needs a different pull, so it is a decision, not
a parameter.

And all **21 colours are now visible**, in three named groups: *Surfaces*, *Program
colours*, *Bright variants*. The first version hid sixteen of them behind a collapsed
section, which is most of the palette — a poor default on the one screen someone
opens *in order to* customise.

`copy_of/1` and `starting_points/0` were **deleted** rather than left as a second
path. Dead production code with a comment is still dead, and the copy is six lines
if it is ever wanted back.

## A test caught a field that could never have worked

`selectionForeground` was in my field list and in **neither surviving preset** — so
a copy was a 20-colour palette against a validator demanding 21, and *no custom
theme could ever have been saved*. Cut, with the better reason on top: unset, xterm
leaves selected text in its own colour, so a selected error line stays red. Adding
it later means adding it to both presets at once, which is a visible change to them
and therefore a decision rather than a fill-in.

## Live apply without a new mechanism

The `<meta>` is server-rendered and cannot change without a reload, so an edit
reaches the browser as a `push_event` that patches the cached table and restyles
every terminal on the page. The browser then mirrors the palette into
`localStorage`, where the **existing** `storage` listener carries it to other
windows. `Settings` is the durable store; `localStorage` is only the cross-window
nudge, which is why load time trusts the `<meta>` and not it. No terminal-hosting
LiveView had to subscribe to anything.

## Refusals, and one form

Every colour is validated as `#rrggbb` and normalized — these strings go to xterm
*and* into the swatch's `style` attribute, so an unvalidated one is a markup
question rather than a styling one. A **partial** palette is refused rather than
merged: the editor always holds a complete one, so a partial save means a form that
lost inputs, and merging would accept it silently. A stored palette that has gone
bad resolves to **no custom theme** rather than a partly applied one.

The editor is **one form** carrying the whole palette, so the params *are* the
palette and there is no per-field event to keep in step with the field list. The hex
is shown rather than typed: a second text input sharing a field's `name` would put
two values on the wire for one field.

## The cull

Industrial, Nord, Monokai survive. Dracula, Solarized, Gruvbox, Tokyo Night, Light
and Matrix are gone from **both** languages, asserted in both. `currentTermTheme()`
now resolves a stored key against the themes that exist, so whoever had picked
Dracula lands on the default *with the swatch highlighted* rather than on a legible
terminal with nothing selected — which would have read as the setting being lost
rather than retired. Losing `light` costs nothing: Industrial already tracks the
app's light theme, which a fixed palette cannot.

`appearance_live.ex` enters the file-size inventory at 1,010 with the cut named (the
terminal-theme block is a coherent component; so is the background catalog).


---

# Where this leaves the Appearance tab

It is now the app's one look-and-feel surface, and it owns five things: backgrounds
for the two surfaces that have them, the app's light/dark theme, the terminal
palette (three presets plus a generated custom one), and the chat's two axes. Two
files carry it — `appearance_live.ex` at 1,010 capped lines and
`BusterClaw.TerminalTheme` — and both have their next cut named in the same comment
that raised their cap.

## What the day added to the anti-drift habit

Three of today's tests assert things nothing in this repo had ever asserted:

- **A stylesheet.** `ChatSkinCssTest` reads `app.css` and holds the skin contract —
  non-default skins have rules, the default has none, no hex literals, no
  `display: none`, every `data-chat-*` selector exists in the markup, every
  font-size a reader reads goes through the scale.
- **A JS/Elixir pair.** `TerminalThemeTest` refuses a palette literal creeping back
  into `theme.js` and checks the removed presets are gone from *both* languages.
  Before today, terminal themes had no test at all and two copies of their list.
- **A generated artifact.** All 360 hues must produce a savable palette, which is
  the only reason to trust a slider that can be dragged anywhere.

## What needs a person

Two entries in LAUNCH **G-40**, both of them "a build and a person looking":

- **The chat skins**: six skin/theme combinations, four controls, and the case a
  test cannot make — that an *old* conversation restyles, and that it reads well.
  Plus Largest text at 150% still fitting.
- **The terminal themes**: each preset with a terminal already open, a spectrum drag
  followed live, two windows agreeing, a restart preserving the custom theme, and
  coloured output (`ls`, `git status`) looking themed under it.

Nothing else is open on either roadmap. Everything deferred was deferred with a
trigger — timestamps, a theme library, import/export, a light generated scheme — and
each one says what would have to be true to pick it up.

---

# Pockets — folders that know what they are for

**A second roadmap ran the whole day in parallel with the two above.** Scoped
08-08, and by tonight Phases 0–4 are shipped, Phase 5 is resolved, Phase 6 is
open space, and Part XI — the app's own art — is live.

| Shipped | Commits |
|---|---|
| Scoped, then the UI placement locked (D9) | `b4bf10d` `aa14a7b` |
| Part X — the long horizon, BusterClaw as Pocket #0 | `fbaf89a` |
| Phase 0 measured, Phase 1 — the Pocket, local only | `a5f88a1` |
| Phase 2a — roles, and `backgrounds/` becomes the first consumer | `fe12bc9` |
| The read fence — `resolve/2`, `asset_url/2`, one asset route | `7d20584` |
| Phase 5 resolved: half shipped, half refused with reasons | `5e4ce41` |
| Phases 2b, 3, 4 — the tab, the mount, the agent's reach | `68ba804` |
| Part XI — dock icons and homepage banner become swappable | `aaa92ef` |
| The upload never uploaded; replaced art is now kept | `64cf81d` |
| Swapped art actually appears, dock included | `5e0edce` |

## The ask was to strengthen the symlink. The answer was to replace it

The operator wanted specialised folders — "Pockets" — that hold a user's chosen
media, with the workspace's symlink style made stronger.

Reading the code said the honest way to strengthen a symlink is to stop using
one. **Three layers of this codebase exist specifically to defeat symlinks:**
`FileManager.within?/2` canonicalizes every path component with `read_link`, and
`Notes` and `Agent.Attachments` both `lstat` and refuse. A Pocket built on
`File.ln_s/2` would be fought by our own security code on every read.

At the filesystem level there is no difference between the link the operator made
on purpose and one an attacker planted. **A mount is the same idea with the
missing half supplied** — an author, a record, a permission, and an off switch.

## Phase 0 paid for itself on a question it was not asked

Four unknowns were scoped. One withdrew (images go through our own controller, so
WKWebView never sees a path). One is still open and blocks nothing. One turned a
week into an afternoon — `appearance.ex` already contained both idioms its
migration needed, *and* the hazard, written by whoever did it last: the pointer
rewrite must run before the pool migration, because **"a slot misread as empty
gets a second image landed on it."**

The fifth was not on the list. Writing the manifest example exposed that `source:`
and `writable:` **cannot be frontmatter fields at all** — `POCKET.md` is inside
the workspace and the agent can write there, so a mount path in the manifest
means an agent mounts a folder by editing Markdown. Mount and permission moved to
an app-owned registry. **The manifest holds description; it never holds
permission**, and that one line is what makes D4 structural rather than a policy
check.

## Three agents, and the seam that caught me

Phases 2b/3/4 went to three agents on disjoint files. The read fence was written
first, by hand, rather than left between them — the chat-attachment lesson from
08-08, where a feature shipped green and did not work because one seam belonged
to nobody.

It was still the seams that produced everything interesting:

- The mounts agent found **D5 pointed at a mechanism that does not exist**.
  `Dispatcher.token_for/1` hands an unattended shift the *full* token and
  `ApiAuth` calls it `:trusted`, so an unattended run presents as trusted. It
  said so plainly instead of working around it.
- It also flagged a defect in *my* file: `Appearance` stores workspace-relative
  pointers, so mounting `backgrounds` would read every slot as empty — the exact
  double-landing hazard above. Refused in both directions.
- **The D4 lockstep caught me.** My own fix put `mount/3` on `Pockets`, making
  the writer transitively reachable from the command surface. The call-graph
  guard failed the build, correctly. Moving it to `Pockets.Operator` restored the
  structural guarantee. Weakening the guard to fit the mistake was never an
  option.

Testing my own contract also caught a catch-all `resolve/2` clause sitting above
the by-name clause and swallowing it — every valid request 404'd while the fence
looked correct.

## Part XI: the operator's design beat both options offered

The dock icons and homepage banner became swappable. Offered a choice between
auto-pick and an operator picker, the operator specified something better:

| The Pocket | What renders |
|---|---|
| absent or empty | the shipped default |
| exactly one image | that image |
| **two or more** | **the text label**, plus a plain error |

**Over-full falls back to text, not to the shipped default.** Picking the first
image would silently choose for them, and the whole reason there is an error is
that the app cannot know which they meant. Falling back to the default would hide
the problem — the dock would look right and the stray file would sit there
forever. Text is the only fallback that differs from *both* correct states. **The
art vanishing is the notification; the message only explains it.**

Every state is derived from a directory listing on read, so **there is no repair
action to build** — no revalidate, no reset, no way to get stuck.

Two things were already true and made it small: the art is real PNGs in
`priv/static`, so the shipped defaults already sit read-only in `priv/` exactly
where X.5.a demands and nothing is seeded; and the dock has rendered a text label
for an item with no image since Calendar shipped without a PNG. **The failure
state is behaviour that predates the roadmap.**

Later the operator added: replaced art is **moved to the workspace root, never
deleted**. A move that fails leaves the original in place — the alternative is
destroying an image we could not preserve.

## "It uploads but nothing changes" — two reports, two different bugs

Both were real, and neither was where it looked.

**The first**: `auto_upload: true` fires `phx-change` on *selection*, while the
entry is still in flight, so consuming there returned `[]` and the file went
nowhere. The fix is the `progress:` callback. A LiveView test drove the component
and **passed on the first run**, which is what located the bug on the client half
rather than in the module. Compounding it: nothing rendered *any* failure — not
config errors, not per-entry errors, not `Brand.put/3`'s own refusal, which was
being thrown away inside the `{:ok, _}` the consumer wants. A refused file looked
exactly like a file that had not been chosen.

**The second, and the better finding**: the art swapped and the dock did not
show it. **A Phoenix app layout is rendered once at mount and is never part of a
later diff.** The dock lives there. No assign can reach it. So the dock nav moved
out into `DockNavLive`, a sticky nested LiveView — the pattern `DockLive` already
established beside it.

Two bugs surfaced inside that fix:

1. The first attempt had `DockNavLive` subscribe and handle the broadcast itself.
   **It never fired** — `ChromeHook` runs for every LiveView including that one
   and `:halt`s the message, so the view's own clause was dead code that read as
   correct.
2. **`render(view)` in LiveViewTest re-renders the whole tree server-side**, so it
   reported the dock as updating when a browser never would have. That is why an
   earlier test passed against a broken dock. The replacement asserts on a
   *second open surface*, which is what distinguishes a diff from a full
   re-render.

## The rule the day kept proving

**A test that passes on the surface you changed proves less than it looks like it
does.** It held for the seam that belonged to nobody on 08-08, for the D4 guard
catching its own author, and twice over for a dock that a full re-render insisted
was fine.

## What needs a person

- **The live walk in a packaged build**: drop art in from Finder, watch a slot go
  to text, remove the extra, watch it come back. Plus a real mount. Filed as one
  sitting in `LAUNCH` **G-40**.

  *(The mount button landed later the same day — this line read "a registry and
  no button yet" for about an hour. Phase 3 is complete, surface included.)*
- **`status_live.ex` finally paid a debt** — the banner moved out rather than the
  file growing, 944 → 929, and the cap followed it down in the same commit. It is
  the first time that ratchet has moved in the direction it is usually ignored in.


---

# Terminal paint — the agent recolours itself, live

**The day's fourth roadmap, and the one that was asked for as a joke.** Scoped
and shipped in an afternoon: the model can now repaint the terminal it is running
in, while you watch it work.

| Shipped | Commits |
|---|---|
| Scoped — four verbs, an agent slot, a legibility floor | `4540daa` |
| Phase 0 — a socket-less writer can reach a terminal | `9a492ae` |
| The agent slot, the floor, the four verbs, the picker, the skill | `193adc5` |

    ./buster-claw run terminal_theme_paint --json '{"colors":{"foreground":"#ff9d2f"}}'

## The toy has a sharp edge, and it is the whole design

These are the first commands in this app that change **what the operator sees**.
That is worth saying plainly, because it is the reason a colour feature needed a
threat model at all:

**An agent that can set `foreground` to `background` can hide its own output.**
Every line still prints and none of it can be read. Setting every ANSI colour to
the background is worse — plain text survives and only colourised output
vanishes, so the terminal still *looks* like it is working. That is not code
execution; it is observability suppression, in the one window where a person
watches the agent.

So the floor is enforced in Elixir on the same call that would otherwise succeed.
It holds for unattended runs, and there is no flag around it.

## Reading first killed the obvious implementation

**The selected terminal theme is client-side only** — `localStorage["bc:term-theme"]`.
Only the custom *palette* is server-side. So a command that writes a Setting
**cannot change what a terminal looks like**, and a command has no socket to push
an event with either.

And `TerminalTheme.topic/0` had **no subscribers at all**. Live apply ran through
`AppearanceLive` pushing directly on the socket that made the edit, which works
only because the editor and the terminal share a browser. A pub/sub that reads as
working wiring, with nothing on the other end.

That made Phase 0 the whole feature's foundation rather than a nicety.

## Measurement corrected the design three times

The legibility floor started as *"every ANSI colour clears 2.0:1"*. Then:

1. **Monokai's ANSI `black` is byte-identical to its background** (ratio 1.00),
   Nord's is 1.24. A per-colour floor would have **refused both shipped
   presets**. The rule now counts: 10 of 16.
2. **Exempting `black` by name would also have refused Nord**, whose
   `brightBlack` is 1.69. The count is load-bearing twice over, not once.
3. **The floor bites at our own accent.** `foreground: "#ff4d1c"` scores
   **4.48** against a floor of 4.5 — the roadmap's own example request, "make the
   foreground orange", fails by 0.02. Correct WCAG behaviour, correctable from
   the returned ratio, and now the first thing the skill warns about, because it
   is what anyone tries first.

An agent also found the roadmap **contradicting itself**: Part III said `paint`
merges over the *currently selected* palette, which its own finding says the
server cannot know.

## Two mistakes of mine, both caught by something other than me

**The first seam draft crashed `TerminalLive`.** Reusing `TerminalTheme.topic/0`
meant `ChromeHook` — which subscribes for every LiveView — immediately delivered
that topic's existing "the operator edited their palette" message to views with
no clause for it. Found by the first test run. The fix was a separate topic, and
the split turned out to be meaningful rather than defensive.

**And `9a492ae` shipped the tree red.** Phase 0 grew `chrome_hook.ex` past its
size cap; I ran format and compile but not the size gate. A parallel agent found
it and refused to fix a file it did not own, which is exactly right. The lesson
is the boring one: **the gate is part of the commit, not part of the review.**

## What the day's four roadmaps have in common

Every one of them was corrected by a guard, a test or a measurement rather than
by re-reading:

- the D4 call-graph lockstep caught **its own author** making a mount writer
  reachable from the command surface;
- `ClawConfirmTest` caught a `data-confirm` that does nothing in the packaged
  webview;
- a dock that every LiveView test insisted was fine was stale in a real browser,
  because `render/1` re-renders the whole tree while a browser gets only the diff;
- and a contrast floor that looked obviously right would have refused the app's
  own themes.

**A test that passes on the surface you changed proves less than it looks like it
does.** Four for four.
