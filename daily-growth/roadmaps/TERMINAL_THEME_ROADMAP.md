# Terminal themes — one source of truth, three presets, and a custom palette

**Scoped 08-09-26 · Status: Phases 0–2 SHIPPED 08-09. Only the operator walk
remains.**

| Phase | State |
|---|---|
| 0 — One list, in Elixir | **DONE** |
| 1 — Cull to Industrial, Nord, Monokai | **DONE** |
| 2 — The custom theme: store, editor, live apply | **DONE** |
| 3 — Decided against / deferred | Below, not silently dropped |

**The ask (operator, 08-09):** a simple UI to pick custom colors and save a theme;
then remove presets, keeping **Industrial, Nord, Monokai**.

---

## Two things that are not what they look like

**1. A theme is up to 22 colors, not three.** The picker's chip shows background,
foreground and accent, which is why the feature reads as simple. An xterm palette
is `background`, `foreground`, `cursor`, `cursorAccent`, `selectionBackground`,
`selectionForeground`, then **8 ANSI colors and 8 bright variants**
(`assets/js/lib/theme.js`).

But the simple reading is half-right, and the half that is right is load-bearing:
**three of the nine presets already omit the 16 ANSI colors** — `industrial`,
`matrix` and `light` define only the six core values. When they are omitted xterm
falls back to its own built-in ANSI palette, so `git status` and `ls` come out in
xterm's red/green/blue rather than the theme's. That is shipped, accepted
behaviour today. It means a six-colour custom theme is **consistent with existing
presets rather than a shortcut** — and it also means "my colours didn't apply to
`ls`" is a real thing a user can hit, which the UI should say out loud rather than
let them discover.

**2. The theme list already exists twice.** `theme.js` holds the palettes;
`AppearanceLive` holds a second, partial copy (`key`, `label`, `bg`, `fg`,
`accent`) for the chips. They are kept in step by a **comment** — *"the actual
xterm palettes live in `assets/js/lib/theme.js` (TERM_THEMES); `key` must
match"* — and by nothing else. There is **no test anywhere** that touches terminal
themes.

So the cull is exactly the shape this repo keeps getting bitten by: a rename or
removal across a JS/Elixir pair where the suite stays green either way. Deleting a
preset from Elixir alone leaves a dead palette in JS; deleting it from JS alone
leaves a chip that selects a theme that no longer exists and silently renders the
default. **That is why Phase 0 comes before the cull the operator asked for
first** — with one list, the cull is a one-line edit and an assertion.

---

## Phase 0 — One list, in Elixir

`BusterClaw.TerminalTheme` becomes the single source of truth: the keys, labels,
chip colours, and full palettes. `AppearanceLive` renders from it; the JS receives
it instead of holding its own copy.

**`industrial` stays dynamic and stays in JS.** It is a `null` sentinel today,
resolved at apply time from live CSS custom properties (`--color-base-100`,
`--color-base-content`, `--color-primary`), which is what makes it the one theme
that follows the app's light/dark switch — there is a `phx:set-theme` listener
that re-applies it. Elixir cannot read computed CSS, so Elixir declares
*"industrial is token-derived"* and JS keeps the resolving. A design that flattened
every theme into a fixed hex table would quietly kill that, and it is the default
theme.

How the palette reaches JS: rendered into the page as a JSON `data-` attribute on
the picker, read by the existing `TermThemePicker` hook. Not a `push_event` —
terminals mount on pages that have no picker, so the data has to be available
wherever a terminal is, which means it belongs on the terminal element or a
document-level carrier rather than in an event only the settings page receives.
**Resolved:** a `<meta name="bc-term-palettes">` in the root layout's head, parsed
once and cached in `theme.js`. A `<meta>` rather than a JSON `<script>` block
because the CSP here is `script-src 'self'` with nothing inline — a data block is
not executed and so not actually blocked, but the repo deliberately removed its
last inline script to drop the nonce, and re-adding a tag that merely *looks* like
a violation buys nothing. No palette literal survives in `theme.js` except the
three CSS-token fallbacks the industrial resolver needs, and a test pins that.

**No visible change, nothing culled.** This phase is done when the picker looks
identical, every open terminal still themes, and a test asserts the Elixir list
and the JS-visible payload agree.

---

## Phase 1 — Cull to Industrial, Nord, Monokai

Delete `solarized`, `dracula`, `gruvbox`, `tokyo-night`, `light`, `matrix`. One
edit in `TerminalTheme` after Phase 0.

**A stored selection naming a deleted preset must resolve to the default**, not
render an unstyled or empty palette — the same rule `ChatSkin` follows, and it is
the only reason this cull is safe for someone currently running Dracula. Worth
noting `light` disappearing costs nothing: `industrial` already tracks the app's
light theme through its tokens, which is strictly better than a fixed light
palette.

Done when the three survive, the six are gone from **both** languages, and a
selection of a removed key degrades to the default — asserted, since that is the
case a real user will hit and nobody will report.

---

## Phase 2 — The custom theme

### It is generated from a spectrum

**Revised 08-09 by the operator, after the copy version shipped.** The entry point
was "Start from Nord / Monokai", which copied a preset. It is now a **hue slider
whose track is the hue wheel**: one number in, all 21 colours out.

What survives from the copy design is the reason it existed — the palette is
**always complete**, so a custom theme can never be the half-themed thing where
your background is custom and `ls` is xterm's defaults. What improves is the first
move: a drag rather than a choice between two names, and every position on the
track is a theme rather than only two.

**The hue tints the surfaces fully; the sixteen program colours are pulled only
15% toward it.** That is the load-bearing rule. A spectrum that slid `red` round to
green would produce a theme that *lies* — red means error output in every program
ever written — so the eight keep their canonical hues and take their cohesion from
shared saturation and lightness. A test asserts red's dominant channel is still red
at six hues around the wheel.

Generation is **deterministic** (the same hue always gives the same palette), which
is what lets the slider be dragged back and forth rather than being a one-shot roll,
and **dark by construction**: a light scheme inverts the lightnesses and needs a
different pull, so it is a decision rather than a parameter. Every surviving preset
is dark.

`copy_of/1` and `starting_points/0` were **deleted** rather than kept as an
alternative path — dead production code with a comment is still dead. `generate/1`
plus per-swatch editing covers the same ground, and the copy is six lines if it is
ever wanted back.

A custom theme still does not follow the app's light/dark switch; only Industrial
does. The UI says so.

### The UI

All **21 colours visible, in three named groups** — *Surfaces* (what the terminal
is when nothing is running), *Program colours* (what `ls` and `git` draw with), and
*Bright variants* (the same eight, for emphasis). Revised 08-09 with the spectrum:
the sixteen program colours had been behind a collapsed `<details>`, which hid
**most of the palette** from someone who came to customise it. Three groups rather
than one grid of 21 because they answer different questions, and the split is also
where the slider's reach ends.

The five core fields are labelled by what they actually do (background, text,
cursor, text under cursor, selection). Not six: `selectionForeground`
was cut, and the test that caught it is worth keeping in mind — **neither surviving
preset sets it**, so a copy could never have satisfied a validator that required
it, and no custom theme could ever have been saved. xterm's behaviour when it is
unset is also the better one (selected text keeps its own colour, so a selected
error line stays red). Adding it later means adding it to both presets at the same
time, which is a visible change to them and therefore a decision rather than a
fill-in. The
16 ANSI colours in a **collapsed** section below, pre-filled from the starting
preset — present for whoever wants them, out of the way for whoever does not.

Native `<input type="color">` swatches, the hex **shown rather than typed** — a
second text input sharing a field's `name` would put two values on the wire for one
field, and "pick a colour" was the ask; a hex field is a power-user affordance that
can be added without touching the store. **One form** carrying the whole palette
with `phx-change`, so the params *are* the palette and there is no per-field event
to keep in step with the field list. **One custom slot, named** — not a
library of saved themes. "Save a theme" was singular, and a list brings rename,
delete, duplicate and an ordering question with it. The store is written so a
second slot is a schema change and not a redesign.

### Storage

`Settings`, not `localStorage`. The selection lives in `localStorage` today and
that is fine for one string, but 22 colours with a name is **data**: it should be
testable, it should be visible to Elixir, and `Appearance` already stores
per-surface palettes in `Settings` as hex triples, so there is precedent and no new
mechanism. **Live apply, resolved:** the `<meta>` is server-rendered and cannot change without
a reload, so an edit reaches the browser as a `push_event` — which patches the
cached palette table and restyles every terminal on that page — and the browser
mirrors the palette into `localStorage`, where the **existing** `storage` listener
carries it to other windows. So `Settings` is the durable store and `localStorage`
is only the cross-window nudge, which is why load time trusts the `<meta>` and not
it. That reuses a mechanism already in place instead of subscribing every
terminal-hosting LiveView to a new topic. (`TerminalTheme.subscribe/0` exists and
broadcasts, for whoever needs server-side notification later.)

**Every colour is validated as `#rrggbb` on the way in.** These strings are handed
to xterm and interpolated into a `style` attribute for the chip preview; an
unvalidated one is a markup-injection question, not a styling one. `Appearance`
already has `sanitize_hex/1` doing exactly this — reuse it rather than writing a
second one.

Done when: a custom theme saves, applies to every open terminal without a reload,
survives a restart, appears in the picker beside the three presets, and a bad hex
is refused rather than stored.

---

## Phase 3 — Decided against, or deferred with a trigger

- **A library of named themes.** One slot now. Revisit when someone actually wants
  two, which is the point at which the list UI earns its keep.
- **Import/export a theme file.** The natural next ask after a library, and it
  inherits the whole validation surface. Not now.
- **Themes as commands** (`terminal_theme_set`, …). No. Note the precedent:
  `Appearance` deliberately has **no commands at all**, because a human click is
  the gate on arbitrary user-authored visual input. Colours are far less dangerous
  than WGSL, but the argument for adding an agent-reachable verb here is "it would
  be neat", which is not one.
- **Theming the 16 ANSI colours by algorithm** (deriving bright variants,
  contrast-checking against the background). Tempting and genuinely useful for
  legibility; it is a feature about colour theory, not about this UI, and it should
  not ride along.

---

## Acceptance

The part a person does: pick each of the three presets and confirm an **already
open** terminal restyles; build a custom theme from Nord with a changed
background; open a second window and confirm both terminals agree; restart the app
and confirm the custom theme is still there and still selected; run something with
coloured output (`ls`, `git status`) under a custom theme with the ANSI section
untouched, and confirm it looks the way the copy said it would. → LAUNCH **G-40**.
