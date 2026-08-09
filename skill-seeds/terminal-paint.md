---
name: terminal-paint
description: How to recolour the terminal you are running in — the four terminal_theme_* verbs, why paint takes a partial colour map and merges, the legibility floor and exactly what it refuses, and three palettes worth wearing.
tier: safe
enabled: true
handler_kind: reference
---

# terminal-paint

A **reference** skill: read this, then use the `terminal_theme_*` commands. Run
each verb through the CLI:

    ./buster-claw run terminal_theme_list --json '{}'

These are the first commands in this app that change **what the operator
sees**. It is a toy and it is meant to be played with — the whole point is that
the operator can watch the terminal they are reading you in change colour while
you work. Read the floor below before you paint, because it decides whether a
paint lands or is refused whole.

## You have your own slot

The picker in Settings → Appearance holds the shipped presets (`industrial`,
`nord`, `monokai`), the operator's own saved theme (`custom`) when they have
made one, and **`agent` — yours**.

`terminal_theme_paint` writes `agent` and nothing else. There is no argument
that points it at `custom`, and there is no verb here that edits, renames or
deletes the operator's theme. That is deliberate rather than an oversight:
`custom` is a palette a person built by hand and named, and overwriting it would
not be a colour change, it would be deleting their work.

The operator sees your slot in the picker, badged as the agent's, and can
select it, keep it, or ignore it. Their own theme is always one click away, and
`terminal_theme_reset` is the way you put things back yourself.

## The four verbs

| Verb | Arguments | Does |
|---|---|---|
| `terminal_theme_list` | none | Every theme key with its label and swatch, which slots exist, and the default |
| `terminal_theme_select` | `key` | Wears that theme, live, in every open terminal |
| `terminal_theme_paint` | `colors` (map), `name` (optional) | Merges `colors` into the **agent** slot and wears it |
| `terminal_theme_reset` | none | Back to the default theme, and clears the agent slot |

    ./buster-claw run terminal_theme_list --json '{}'
    ./buster-claw run terminal_theme_select --json '{"key":"nord"}'
    ./buster-claw run terminal_theme_paint --json '{"colors":{"foreground":"#ff9d2f"}}'
    ./buster-claw run terminal_theme_reset --json '{}'

`terminal_theme_list` is also the authority on two things this file is not: its
`fields` list is the exact set of colour names `paint` accepts, and its `slots`
say which of `custom` and `agent` currently holds a saved palette. A theme it
marks `token_derived` (that is `industrial`) carries no fixed colours at all —
it follows the app's own light/dark setting and is resolved in the browser.

Two things `list` cannot tell you, and it is better to know than to guess:

- **Which theme is on screen right now.** The selection lives in the operator's
  browser, not on the server. `list` says what exists; it does not say what is
  worn. If you need to be sure, `select` or `paint` something — those are the
  acts that decide it.
- **What the operator will think of it.** There is no vision on this path. You
  can report the hexes you set and that the floor accepted them. You cannot
  report that it looks good, and saying so is the one claim here that costs
  trust outright.

`reset` clears rather than restores. There is no record of what the operator
had selected before you started, so the honest reset is the **default theme** —
a state they recognise — rather than a guess.

## `paint` takes a partial map, and merges

This is the one place this surface differs from the operator's editor, which
always submits a complete 21-colour palette.

**"Make the foreground orange" is one field, not twenty-one.**

    ./buster-claw run terminal_theme_paint --json '{"colors":{"foreground":"#ff9d2f"}}'

`colors` merges over whatever is already in your slot, so a paint is a *patch*.
Send the fields you mean to change and leave the rest alone; a second call
changing `cursor` keeps the foreground you set on the first.

The first paint has nothing of yours to merge over, so it merges over **Monokai**
— a complete dark palette with contrast to spare. It cannot be the default
theme: `industrial` is token-derived and has no fixed colours to merge onto.
This matters when you patch a single field: `{"background":"#f4f1ea"}` on an
empty slot gives you Monokai's near-white `foreground` on a near-white
background, which the floor below will refuse. Paint the surfaces together, or
paint a whole palette.

The fields are the five core values —

`background`, `foreground`, `cursor`, `cursorAccent` (the character *under* the
cursor), `selectionBackground`

— and the sixteen ANSI slots that colour `ls`, `git status` and every other
program that emits colour:

`black` `red` `green` `yellow` `blue` `magenta` `cyan` `white`
`brightBlack` `brightRed` `brightGreen` `brightYellow` `brightBlue`
`brightMagenta` `brightCyan` `brightWhite`

Every value is a `#rrggbb` literal — six digits, with the `#`. Three-digit
shorthand, `rgb()` and colour names are all refused.

**A merge that fails is refused entire.** The result is validated as a whole
palette after merging, so one bad field does not land half a theme; the slot
keeps the last palette that validated. Do not retry the same call hoping for a
different answer — read which field it named and fix that one.

`name` is optional, is capped at 40 characters, and is what the operator sees
beside your swatch in the picker. Give it one when the palette has a point
("Sodium", "Blueprint"); omitting it keeps the name the slot already had, so a
repaint does not have to re-state a name it did not change.

## The legibility floor

A palette that the operator could not read is refused. This is checked in
Elixir, on the same call that would otherwise succeed, so it holds for
unattended runs too.

| Pair | Floor |
|---|---|
| `foreground` against `background` | **4.5 : 1** |
| `cursor` against `background` | **2.0 : 1** |
| the 16 ANSI colours against `background` | **at least 10 of the 16 clear 2.0 : 1** |

Contrast is the WCAG ratio `(L₁ + 0.05) / (L₂ + 0.05)` over relative luminance.

**Why this exists, said plainly.** The terminal is where the operator watches
you work. An agent that can set `foreground` to `background` can hide its own
output — every line still prints and none of it can be read. Setting every ANSI
colour to the background is worse, because plain text survives and only the
coloured output vanishes, so the terminal still *looks* like it is working. That
is not code execution; it is observability suppression, and it is the one thing
this feature is not allowed to do.

So the floor is not an obstacle to route around. **There is no route around it**
— no flag, no tier, no second verb — and looking for one is the wrong instinct.
If a palette you like is refused, lighten the offending colour and paint again;
you will lose nothing that mattered.

The refusal comes back as a sentence naming the field and the ratio it scored —
*"foreground scores 1.83:1 contrast against the background"* — so you can fix
that one field and paint again. Pass that on rather than reporting "it didn't
work"; a named field is a one-line correction and "invalid" is a guess.

**What the floor deliberately does not do.** It does not check contrast
*between* ANSI colours — red on green is hideous and readable, and that is
allowed. It does not check `cursorAccent` or `selectionBackground`, because
neither carries your output. And it does not constrain the operator: they can
do any of this by hand in Settings. This is a rule about you.

Two consequences worth holding on to:

1. **A near-black ANSI `black` is fine, and normal.** Both shipped presets have
   one — Monokai's `black` is byte-identical to its background. That is what
   ANSI black *is* in a dark terminal, which is exactly why the rule counts 10
   of 16 rather than requiring all 16.
2. **A light background is allowed**, and the first field to fall below the
   floor is `brightWhite`. If you paint a pale terminal, darken the whites
   rather than shipping sixteen near-invisible colours.

### Two refusals you will hit first, and how to read them

**The brand orange fails as a foreground, by 0.02.** `foreground: "#ff4d1c"` over
the merge base scores **4.48** against a floor of 4.5. That is a correct WCAG
refusal, not a bug, and it is the most likely first thing anyone tries — "make
the terminal orange" is the obvious request. The returned ratio is what makes it
fixable: lighten a little and it passes (`#ff6a3c` clears). Use the accent for
`cursor`, `red` or `brightRed`, where the floor is 2.0 and it sails through.

**A misspelled field is refused, not ignored.** `{"foregruond": "#ffffff"}`
returns `{:unknown_field, "foregruond"}` rather than quietly merging nothing and
reporting success. Merging costs the typo detection that a complete-palette save
gets for free, so the field names are checked instead — pass only real palette
fields, and nothing else, in `colors`.

## Three palettes worth wearing

All three clear the floor with room to spare. They are complete, so each one is
a single `paint` with nothing inherited.

### Hazard — the app's own colours

Near-black, bone text, and the hazard orange this whole app is built around.
The safe pick when the operator has not asked for anything in particular.
`foreground:background` is 16.6:1.

    ./buster-claw run terminal_theme_paint --json '{"name":"Hazard","colors":{
      "background":"#121212","foreground":"#f4f1ea","cursor":"#ff4d1c",
      "cursorAccent":"#121212","selectionBackground":"#3a2418",
      "black":"#2b2b2b","red":"#ff4d1c","green":"#9ec37a","yellow":"#e8b13a",
      "blue":"#6aa9c9","magenta":"#c98fb0","cyan":"#6fc6bd","white":"#d8d3c7",
      "brightBlack":"#6b6b6b","brightRed":"#ff7a52","brightGreen":"#b9d99a",
      "brightYellow":"#f5cc6a","brightBlue":"#93c7e2","brightMagenta":"#e0b0cb",
      "brightCyan":"#96ded6","brightWhite":"#f4f1ea"}}'

### Sodium — amber on tar

A street-lamp terminal. Every colour is pulled hard toward amber, so the whole
screen reads as one warm object; `red` and `magenta` stay separable enough that
error output still announces itself. Cursor is 9.4:1.

    ./buster-claw run terminal_theme_paint --json '{"name":"Sodium","colors":{
      "background":"#100c06","foreground":"#f2d5a0","cursor":"#ff9d2f",
      "cursorAccent":"#100c06","selectionBackground":"#3d2c14",
      "black":"#241a0c","red":"#ff6a45","green":"#c2b258","yellow":"#ffb636",
      "blue":"#b08d5a","magenta":"#e08a72","cyan":"#d6a95e","white":"#e6cfa6",
      "brightBlack":"#7a6647","brightRed":"#ff8f6d","brightGreen":"#dccb78",
      "brightYellow":"#ffd07a","brightBlue":"#d0ae7c","brightMagenta":"#ffb098",
      "brightCyan":"#f0c884","brightWhite":"#fbeccb"}}'

### Blueprint — cyan ink on navy paper

Cool and high-contrast, the opposite mood to the other two. Good when the
operator wants something calm to read a long log in.

    ./buster-claw run terminal_theme_paint --json '{"name":"Blueprint","colors":{
      "background":"#0d1b2a","foreground":"#dbe7f3","cursor":"#4cc9f0",
      "cursorAccent":"#0d1b2a","selectionBackground":"#22415e",
      "black":"#16293b","red":"#e5707f","green":"#7fc8a9","yellow":"#e3c17a",
      "blue":"#6fa8dc","magenta":"#b39ddb","cyan":"#4cc9f0","white":"#c5d4e3",
      "brightBlack":"#5b7188","brightRed":"#f593a0","brightGreen":"#a2ddc4",
      "brightYellow":"#f0d79c","brightBlue":"#9cc6ee","brightMagenta":"#cbb9e8",
      "brightCyan":"#8ce0f7","brightWhite":"#eef5fc"}}'

To tweak one instead of replacing it, paint the base and then patch:

    ./buster-claw run terminal_theme_paint --json '{"colors":{"cursor":"#ff4d1c"}}'

## When to reach for this, and when not

- **The operator asks.** "Make the terminal green", "paint yourself something
  for Halloween", "go back to normal" — all four verbs, in order.
- **Say what you did, in hexes.** Name the palette, the background and
  foreground you set, and that it is in the agent slot they can deselect. Then
  stop; you cannot see the result.
- **Do not repaint unprompted.** Once per ask. A terminal that changes colour on
  its own schedule is not a toy, it is a distraction sitting on top of the
  operator's work, and one run repainting between every step would be the fastest
  way to get this feature switched off.
- **Do not use colour to signal.** Turning the terminal red because a build
  failed is a notification invented on a surface that has none, and the operator
  has not agreed to read it. Say "the build failed" instead.
- **This is the terminal only.** It is not the app's light/dark theme, not the
  homepage shader, not the chat's look, and not a `.wgsl` file. Those are the
  operator's clicks, on purpose — a palette is 21 validated numbers, a shader is
  code, and that line is not moving. If the operator wants any of them changed,
  say so plainly and let them.
