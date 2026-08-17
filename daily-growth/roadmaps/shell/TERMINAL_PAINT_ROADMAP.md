# Terminal paint — the agent changes its own colours, live

**Scoped 08-09-26 · Status: SCOPED, nothing built.**

> ### The one-sentence version
>
> **Four `terminal_theme_*` commands that let the model recolour the terminal it
> is running in, live, into its own theme slot — never the operator's — and never
> into a palette the operator could not read.**

> ### Why this is funny, and why that is the point
>
> The ask (operator, 08-09) was for *"something funny"*: the model changing its
> own appearance in real time, in the terminal you are watching it work in. That
> is a good toy. It is also the first time anything in this app lets the agent
> change **what the operator sees**, which makes it a small feature with a sharp
> edge — see [I.1](#i1--appearance-has-no-command-surface-and-that-is-a-decision-not-a-gap)
> and [Part IV](#part-iv--the-legibility-floor).

> ### Read this before planning around it
>
> **This roadmap sits on top of code that shipped hours ago.**
> `TERMINAL_THEME_ROADMAP` (archived 08-17) landed `d0d1363`, `8634308`, `876a7f4` on 08-09 in a
> concurrent session. Everything in Part I was read from that code as committed.
> If that roadmap is still moving, **Phase 0 is where the two meet** — and
> [I.3](#i3--terminaltheme-broadcasts-into-an-empty-room) is a finding its author
> will want either way.

---

## Contents

- [Part I — What the code already tells us](#part-i--what-the-code-already-tells-us)
- [Part II — Locked decisions](#part-ii--locked-decisions)
- [Part III — The verbs](#part-iii--the-verbs)
- [Part IV — The legibility floor](#part-iv--the-legibility-floor)
- [Part V — The phases](#part-v--the-phases)
- [Part VI — What this does not solve](#part-vi--what-this-does-not-solve)
- [Part VII — Risks](#part-vii--risks)
- [Part VIII — Open questions for the operator](#part-viii--open-questions-for-the-operator)

---

## Part I — What the code already tells us

Five findings. Two of them mean the obvious implementation **cannot work**, and
one is a live defect in code that shipped this morning.

### I.1 — Appearance has no command surface, and that is a decision, not a gap

There is **no appearance, background or theme verb anywhere in the catalog**.
`terminal_command_set` and `terminal_tab_open` are the only `terminal_*` verbs,
and neither touches how anything looks.

That is not an oversight waiting to be filled. `CHAT_SKINS_ROADMAP` Phase 4 wrote
the reason down while cutting operator-authored skins:

> *"`Appearance` accepts arbitrary user `.wgsl` but has **no commands at all**,
> because only a human click may ever put user-authored GPU code on screen."*

**This roadmap is the first thing to cross that line, so it owes the argument.**

> **The line moved twice on 08-15, after this was written.** `background_list` /
> `background_set` shipped (selection became a command), and then
> `AGENT_APPLIED_SHADERS` made a workspace shader applicable once the operator
> has applied its exact bytes themselves. The quote above is preserved as the
> position this roadmap argued against, not as current behaviour. **The property
> that survived both moves is narrower and is the one to argue against now:** GPU
> code no human has ever looked at cannot reach the screen from a command.
It is made in [D1](#d1--a-palette-is-data-a-shader-is-code-and-that-is-the-whole-argument).

### I.2 — The active theme is client-side only. The server cannot see it or set it.

The selected theme lives in **`localStorage["bc:term-theme"]`**
(`assets/js/lib/theme.js:13`). `TerminalTheme`'s only `Settings` keys are
`terminal_custom_theme_name`, `_colors` and `_hue` — **the custom palette is
stored server-side; which theme is *active* is not.**

So the naive implementation — a command that writes a Setting — **cannot change
what a terminal looks like.** Nothing on the server knows the current theme, and
nothing on the server can select one. A command has no socket, so it cannot
`push_event` either.

**This is the finding that decides the shape of Phase 0.** Live apply is not a
nicety here; without it there is no feature.

### I.3 — `TerminalTheme` broadcasts into an empty room

`TerminalTheme.topic/0` (`:502`) and `subscribe/0` (`:505`) exist, and
`broadcast/0` (`:507`) fires on every `set_custom/3`. **Nothing subscribes.**
`grep` finds `TerminalTheme.subscribe` at exactly one site — its own definition.

Live apply today runs through `AppearanceLive` calling
`push_event("bc-term-custom", …)` directly (`:167`, `:728`), on the socket that
made the change. It works because the editor and the terminal are in the same
browser, and it is **the reason a change made outside that LiveView reaches
nothing.**

> **Worth handing back to the terminal-theme roadmap's author regardless of this
> one.** A PubSub topic with no subscriber is not a bug today — the direct
> `push_event` covers the only writer there is — but it reads as wiring that
> works, and the next writer to trust it (this one) would have found nothing.

### I.4 — The validator this needs already exists

`validate_palette/1` requires **every one of the 21 fields** (5 core + 16 ANSI)
and each as `#rrggbb`; a partial palette is refused rather than merged, and a
stored palette that has lost a field resolves to `nil` rather than to something
half-applied. `fields/0`, `core_fields/0` and `ansi_fields/0` name them.

**So the shape of a palette is already guarded.** What is *not* guarded — and
cannot be, because it was never a threat from a human using a colour picker — is
whether the result can be read. That is [Part IV](#part-iv--the-legibility-floor).

### I.5 — There is exactly one custom slot, and it is the operator's

`@custom_key "custom"`, one name, one palette, one hue. `set_custom/3`
**overwrites it wholesale.**

An agent writing there would silently destroy a theme the operator built with a
spectrum picker and named. That is not a colour change; it is deleting someone's
work. See [D3](#d3--the-agent-gets-its-own-slot-and-never-touches-the-operators).

---

## Part II — Locked decisions

### D1 — A palette is data; a shader is code. That is the whole argument.

The precedent in [I.1](#i1--appearance-has-no-command-surface-and-that-is-a-decision-not-a-gap)
refuses commands for `.wgsl` because a shader is **arbitrary GPU code**, and the
BEAM cannot sandbox what it hands to a GPU any more than it can sandbox Elixir.

A palette is **21 validated `#rrggbb` values**. It cannot execute, cannot escape,
and is already refused wholesale if one field is malformed. It sits inside the
same rule Pockets inherited from the deleted extension mechanism — *a bundle the
app interprets is never executable code* — rather than fighting it.

**The `.wgsl` refusal stands unchanged.** This does not open appearance to the
agent; it opens *one table of validated colours*.

### D2 — A palette the operator could not read is refused

The agent may make the terminal ugly. It may not make it **invisible**.

Enforced by a contrast floor, not by trust ([Part IV](#part-iv--the-legibility-floor)).
The reason is not aesthetic: the terminal is where an operator watches the agent
work, and an agent that can set `foreground` to `background` can **hide its own
output**. That is not code execution — it is observability suppression, and this
app has an entire audit layer premised on the operator being able to see.

### D3 — The agent gets its own slot, and never touches the operator's

A new theme key, `agent`, with its own `Settings` keys, appearing in the picker
beside `custom`. `set_custom/3` is **not** called by any command.

The operator's saved theme, its name and its hue survive whatever the model does.
And the picker gains an honest label — the operator can see *the agent's* theme is
a separate thing they can select, keep, or ignore.

### D4 — `:restricted`, ungated, and allowed unattended

- **Reads** (`terminal_theme_list`) are `:safe`.
- **Writes** are `type: :mutate`, `tier: :restricted`. This changes the
  operator's environment without asking, which is exactly what `:restricted`
  means; `:safe` would let an untrusted caller repaint the machine.
- **Not gated.** A confirmation dialog for a colour is theatre, and it would make
  the toy unusable in the one place it is meant to be fun.
- **Unattended is allowed**, and that is only defensible *because* of D2. Without
  the floor, an unattended run could go dark and nobody would be watching.

### D5 — No new live-apply mechanism. Wire the one that exists.

[I.3](#i3--terminaltheme-broadcasts-into-an-empty-room) found a topic with no
subscribers. Phase 0 gives it one, and `AppearanceLive`'s direct `push_event`
keeps working unchanged — the broadcast is an *additional* path for writers that
have no socket, not a replacement for the one that does.

The subscriber shape is already proven next door: `BusterClawWeb.ChromeHook`
subscribes once for every LiveView (`POCKETS_ROADMAP` Part XI needed exactly this
for the dock). **One hook, every open surface**, rather than a subscribe in each
mount.

### D6 — Four verbs, and no more until something asks

Listed in [Part III](#part-iii--the-verbs). No import, no export, no random, no
animation, no per-surface theming. This is a toy with a sharp edge; the sharp
edge is the part that deserves the effort.

---

## Part III — The verbs

| Verb | Type / tier | Args | Does |
|---|---|---|---|
| `terminal_theme_list` | read · safe | — | every theme key, its label, its swatch, and which slots exist |
| `terminal_theme_select` | mutate · restricted | `key` | selects a theme, live, in every open terminal |
| `terminal_theme_paint` | mutate · restricted | `colors` (map), `name` (optional) | writes the **agent** slot and selects it |
| `terminal_theme_reset` | mutate · restricted | — | back to the default theme, and clears the agent slot |

**`terminal_theme_paint` takes a partial map on purpose**, and it is the one
place this diverges from `set_custom/3`. The operator's editor always holds a
complete palette, so a partial save there means a broken form. The agent has no
form — it wants to say *"make the foreground orange"* — so `paint` **merges** and
validates the result as a whole. A merge that fails the floor or the format is
refused entire.

> **Corrected 08-09, and it was this document contradicting itself.** The line
> above first said `paint` merges over *the currently selected palette*. It
> cannot: [I.2](#i2--the-active-theme-is-client-side-only-the-server-cannot-see-it-or-set-it)
> is that the server does not know the selection. The base is the **agent's own
> palette** when it has painted before — so paints accumulate — and a fixed
> preset otherwise. Caught by the agent implementing it, not by re-reading.

**The merge base is `monokai`, not the default.** `industrial` is
`palette: nil` — token-derived — so there is nothing to merge onto. Monokai
carries the most contrast headroom of the shipped presets (fg:bg 13.94 vs Nord's
9.25; 15 of 16 ANSI clearing 2.0 vs Nord's 14), which makes a one-field paint
least likely to be refused for a colour the model never touched.

**`reset` clears rather than restores.** There is no memory of what the operator
had selected (it is in their browser's `localStorage`, per
[I.2](#i2--the-active-theme-is-client-side-only-the-server-cannot-see-it-or-set-it)),
so the honest reset is *the default theme*, which is a state the operator can
recognise, rather than a guess at what they were using.

---

## Part IV — The legibility floor

The interesting half of this roadmap.

### What is being prevented

Not ugliness. **Disappearance.** Three concrete failures, all reachable from a
palette that passes `validate_palette/1` today:

1. `foreground` == `background` — every line the agent prints is invisible.
2. Every ANSI colour == `background` — colourised output (`ls`, `git status`,
   the agent's own status lines) vanishes while plain text survives, which is
   *worse*, because the terminal still looks like it is working.
3. `cursor` == `background` — the operator cannot see where input goes.

### The rule

Relative luminance per WCAG 2.x, contrast ratio `(L₁ + 0.05) / (L₂ + 0.05)`:

| Pair | Floor | Why this number |
|---|---|---|
| `foreground` : `background` | **4.5 : 1** | body text the operator reads continuously |
| `cursor` : `background` | **2.0 : 1** | a position marker, not prose |
| the 16 ANSI colours | **at least 10 of 16 clear 2.0 : 1** | see below — a per-colour floor is provably wrong |

### The per-colour ANSI floor was wrong, and the shipped presets prove it

**Measured before building, and it killed the first draft of this table.**
Computing WCAG contrast against `background` for every colour in the two presets
that carry a palette:

| Preset | `foreground` : `background` | worst ANSI |
|---|---|---|
| Monokai | **13.94** | **1.00** — `black` |
| Nord | **9.25** | **1.24** — `black` |

**Monokai's ANSI `black` is byte-identical to its background**, and Nord's is
within a rounding error. That is not a flaw in those themes; it is what ANSI
black *is* in a dark terminal. A flat "every ANSI colour clears 2.0:1" floor
would have **refused both shipped presets** — the exact failure
[Part VII](#part-vii--risks) warned about, confirmed in one measurement.

So the rule counts instead of requiring. The threat was never "one dim colour";
it was **"every colour at background", which blanks colourised output while plain
text keeps working**. Requiring 10 of 16 permits `black` (and a dim `brightBlack`
beside it) and still makes a wholesale blackout impossible.

**`industrial` has `palette: nil`** — it defers to the app's own theme tokens
rather than shipping 21 colours — so it has nothing to measure and nothing to
refuse. Worth knowing before writing a test that iterates presets and expects a
palette from each.

**Two things this table missed, found while implementing it.** Nord's
`brightBlack` is **1.69** — also under the floor — so exempting `black` *by name*
would still have refused Nord. The count is load-bearing twice over, not once.
And the failure names the **10th-best** ANSI colour rather than the worst: the
worst is `black` in every dark theme, and `black` is precisely what the count
exists to permit, so naming it would send the model to fix the wrong colour.

**The floor bites at the app's own accent.** `foreground: "#ff4d1c"` over Monokai
scores **4.48** and is refused by 0.02 — *this roadmap's own example request,
"make the foreground orange", fails at the brand orange.* That is a correct WCAG
refusal and the returned ratio makes it correctable (`#ff6a3c` passes), but the
model will hit it on the first try, so the skill has to say so.

**Refusal is whole-palette**, matching `validate_palette/1`: `{:error,
{:illegible, field, ratio}}` naming the offending field and what it scored, so
the model can correct it rather than guess.

### Why a floor and not a warning

A warning is a thing an unattended run cannot read. The floor has to hold at the
point of the write, in Elixir, on the same call that would otherwise succeed.

### What the floor deliberately does not do

- It does not enforce contrast **between** ANSI colours. Red on green is
  hideous and readable; that is the operator's problem and the model's joke.
- It does not check `selectionBackground` or `cursorAccent` — neither carries
  the agent's output.
- **It cannot stop the operator** doing any of this by hand in the editor. The
  floor is a constraint on the *agent*, not a global legibility policy, and
  pretending otherwise would be a second, weaker copy of a design nobody asked
  for.

---

## Part V — The phases

### Phase 0 — Make a server-side change reach a terminal at all

**Nothing else is possible until this works**, per
[I.2](#i2--the-active-theme-is-client-side-only-the-server-cannot-see-it-or-set-it)
and [I.3](#i3--terminaltheme-broadcasts-into-an-empty-room).

- `ChromeHook` subscribes to `TerminalTheme.topic/0` and, on a change,
  `push_event`s to the client — the same hook that already does this for brand
  art, extended rather than duplicated.
- A client handler that applies a *selection* (writes `localStorage` and calls
  the existing `applyTermTheme`), beside the `bc-term-custom` handler that
  already applies a *palette*.
- **Proof it works before any command exists:** a test that broadcasts and
  asserts the event reaches a mounted LiveView. `AppearanceLive`'s existing
  direct path must still work — assert both.

### Phase 1 — The agent slot

`agent` as a second dynamic theme key beside `custom`, with its own `Settings`
keys, in `themes/0` and the picker. **No commands yet.** The operator can select
it from Settings and see an empty/placeholder state.

Doing this before the verbs means the slot's shape is settled while it is still
easy to change, and the picker's handling of *two* dynamic slots is proven before
anything writes to one.

### Phase 2 — The legibility floor

`TerminalTheme.legible?/1` (or `check_legibility/1` returning the offending
field), with the table from [Part IV](#part-iv--the-legibility-floor) and tests
that walk each failure case: fg==bg, every ANSI at bg, cursor at bg, and a
deliberately hideous-but-legible palette that must **pass**.

Written before the verbs so no verb ever ships without it.

### Phase 3 — The four verbs

`terminal_theme_list`, `_select`, `_paint`, `_reset`, in a
`commands/catalog/terminal_theme.ex` + `commands/terminal_theme.ex` pair, with
the catalog/handler arg lockstep this codebase requires.

**Every argument a handler reads must be declared in the catalog** — the
Pockets work treated a handler reading an undeclared arg as the same class of
error as inventing a verb, and that rule holds here.

### Phase 4 — A reference skill, so the joke lands

`skill-seeds/terminal-paint.md`. A reference skill (read, not run) that teaches
what the slots are, that `paint` merges, that the floor exists and what it
refuses — and, because this is a toy, **two or three palettes worth having**.
A capability the model has to discover by trial reads as broken.

### Phase 5 — Open space

Deliberately empty. Animation, per-run themes and "match the wallpaper" are all
things to want *after* watching it work once.

---

## Part VI — What this does not solve

**It does not make appearance agent-controllable.** One table of validated
colours in one surface. Shaders, chat skins, backgrounds and brand art are all
untouched, and the `.wgsl` refusal is unchanged.

**It does not give the operator a way to lock it.** There is no "don't let the
agent repaint my terminal" switch, because there is no other agent-controlled
appearance to build such a switch against. If a second one arrives, they should
share one control rather than growing two —
[Part VIII](#part-viii--open-questions-for-the-operator) asks.

**It does not survive a browser.** Selection is `localStorage`
([I.2](#i2--the-active-theme-is-client-side-only-the-server-cannot-see-it-or-set-it)),
so a different browser profile sees its own theme. That is the existing design
and this roadmap does not change it.

---

## Part VII — Risks

**Building on hours-old code.** Part I was read from `876a7f4`. If the
terminal-theme roadmap is still moving, `themes/0` and the picker are the
collision points, and Phase 1 is what touches them.

**The floor's numbers are a judgement, and one of them was already wrong.**
4.5:1 is WCAG's body-text ratio; the rest is chosen rather than derived. The
first draft's per-colour ANSI floor would have refused both shipped presets, and
[Part IV](#part-iv--the-legibility-floor) now carries the measurement that killed
it. **The remaining judgement is "10 of 16"** — Phase 2 should measure any theme
a person actually likes before trusting that number.

**It is a toy that writes to the operator's environment.** The novelty wears off
and the palette stays. `reset` exists for that, and the agent slot means the
operator's own theme is one click away, always.

---

## Part VIII — Open questions for the operator

1. **Should the agent's theme be selected automatically when it paints, or offered?**
   `paint` selecting its own slot is what makes it "live" and is the whole joke.
   Offering instead would make it a suggestion the operator accepts. **I lean
   auto-select** — it is the ask — but it is the difference between a toy and a
   notification.

2. **Should there be a kill switch?** Part VI says no because there is nothing
   else to build it against. If you want one now, the honest place is Settings →
   Appearance beside the theme picker, and it should be a *tier* decision
   (`terminal_theme_*` refused for the agent) rather than a flag the agent could
   read and route around.

3. **Is "10 of 16" the right count?** Measuring the two presets that have a
   palette settled that a *per-colour* floor is wrong (see
   [Part IV](#part-iv--the-legibility-floor)), but not what the count should be.
   Monokai and Nord both clear 10 comfortably. If you have a theme you like that
   does not, the number moves rather than the theme.
