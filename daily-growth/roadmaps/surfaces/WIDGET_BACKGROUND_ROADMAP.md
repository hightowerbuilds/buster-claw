# The widget's sky — making the corner card a third background surface

**Scoped 08-15-26 · Status: UNBUILT. D1 and D2 DECIDED 08-15 — the surface is
the Time & Place panel, and `daycycle` stays out of the catalog. VII.3 is still
open and is what gates starting.**

Operator: *"incorporate the widget on the home page into the shader background
feature. We want the current WGSL to default but we want the other shader
patterns to be options, we want images to be options, and it needs to be part of
Pockets. We also need a UI on the Appearance tab."*

> ### The one-sentence version
>
> **The widget already renders a shader; it just renders one nobody can change.**
> Making it selectable is mostly deleting a hardcoded attribute — except that the
> file it lives in is `FROZEN` by the size gate, and the shader it defaults to
> is not in the catalog it would have to be selected from.

---

## Contents

- [Part I — What the code says today](#part-i--what-the-code-says-today)
- [Part II — The trap: `u.lens` already has two owners](#part-ii--the-trap-ulens-already-has-two-owners)
- [Part III — The decisions](#part-iii--the-decisions)
- [Part IV — The phases](#part-iv--the-phases)
- [Part V — Out of scope](#part-v--out-of-scope)
- [Part VI — Risks](#part-vi--risks)
- [Part VII — Open questions for the operator](#part-vii--open-questions-for-the-operator)

---

## Part I — What the code says today

### I.1 — The widget's shader is hardcoded, in one place

`components/home_widget.ex`, `place_panel/1`: a literal
`data-shader="daycycle" data-daylight="true"` on a `SmokeBackground` mount. The
clock and the current conditions float above it in glass; the card's
`ic-scanlines` overlay sits on top of everything.

**Only the Time & Place sub-tab has it.** Contacts and Notify are lists on the
plain card. That distinction is [D1](#d1--which-surface-is-this-exactly).

### I.2 — `daycycle` is in the shader registry and NOT in the catalog

`assets/js/smoke/shaders.js` exports it alongside `smoke`, `waves`, `mandel`,
`weather`, `face`, `sevenseg`, `keypad`, `veil`. `Appearance.@builtin_shaders` is
only `smoke waves mandel weather veil`.

That file's own comment already states the rule this roadmap runs into: *"being
in this registry is not the same as being offered — `face`/`sevenseg`/`keypad`
are here for other surfaces and have never been background options either."*
`daycycle` is currently in that group. Making it the widget's *default* means
deciding whether it joins the catalog — [D2](#d2--does-daycycle-join-the-catalog).

### I.3 — The renderer already exists, and already refuses to duplicate itself

`BusterClawWeb.ShaderCanvas` is the hook-owned canvas for the three surfaces that
have one (homepage, terminal, split). Its moduledoc records why it exists: those
three had thirteen identical lines copied out and **the copies had already
drifted** — the homepage keyed `data-shader` off `bg.mode` while the others used
`bg.shader`.

So the widget should render through `ShaderCanvas`, not gain a fourth copy. One
thing is missing from it: **`ShaderCanvas` does not emit `data-daylight`.** See
[D3](#d3--data-daylight-follows-the-shader-not-the-mount).

Its id is a **remount key**, and its moduledoc warns in bold: everything the hook
reads at mount is folded into the id, and *"leave a field out of the key and that
setting silently stops applying"* until a page reload. Anything new the widget
feeds the canvas has to go into that key.

### I.4 — `home_widget.ex` is 699 lines and **FROZEN**

This is the constraint that reorders the work, so it is not in a phase — it is
before them.

`check_file_sizes.sh` has two tiers. `HELD` means "decomposed, capped at roughly
+10%". **`FROZEN` means "a target of an unstarted roadmap phase, capped at
TODAY'S size with no headroom, because these are already too big."** A `FROZEN`
file may shrink and may never grow, by a single line.

Every other part of this feature is small. This one is a decomposition, and
pretending otherwise is how the cap gets raised "just this once" — which the gate
header says undid two previous decompositions.

### I.4b — All three panels are always in the DOM, and the canvas never stops

Found while doing Phase 0, and it changes what Phase 2 has to measure.

The card does **not** `:if` its tabs. It renders all three and hides two with a
`hidden` class, so **the Time & Place canvas is mounted and animating whichever
tab you are looking at** — including Contacts and Notify, where it is invisible.

That is the opposite of the call `PhoneComponent` made, and that module's
moduledoc says why it went the other way: its panels are `:if`-ed *"rather than
hidden, so their `phx-update="ignore"` shader canvases are torn down and
remounted on a tab switch instead of animating unseen."* Two surfaces in the same
app, opposite answers, and the widget has the one that keeps drawing.

Nothing here is broken today — it is one small canvas. But Phase 2's risk about
canvas count is worse than scoped: the widget's is not "a third canvas when the
widget is showing", it is a third canvas **always**. If that measurement goes
badly, switching the wrappers to `:if` is the cheaper fix than dropping the
feature, and it brings the widget in line with the phone.

### I.5 — One table drives every surface, and a third entry ripples

`Appearance.@surfaces` is a map of `:home` and `:terminal`, each with a mode key,
custom-palette key, colours key, PubSub topic, message name, label and default.
Everything below is written against that table rather than per-surface, which is
the reason this feature is cheap at all.

`Appearance.surfaces/0` is read by:

| Reader | What a third entry does |
|---|---|
| `AppearanceLive`, `:for={surface <- Appearance.surfaces()}` | a **third button on every catalog row**, twice (two render sites) |
| `background_list` | a third entry in `surfaces` |
| `background_set` | a third valid `surface` argument |
| `Catalog.Appearance` descriptions | say "`terminal` or `home`" in prose — both entries |
| `Explained.Shaders`, the Manual | teach two surfaces |
| `AppearanceLive`'s tests, `commands/appearance_test.exs` | assert the pair |

None is hard. All of them are the actual work.

---

## Part II — The trap: `u.lens` already has two owners

`SmokeBackground` writes the `lens` uniform twice, for two unrelated features:

1. **`data-daylight`** mounts get `lens.x = local day fraction` — that is what
   makes `daycycle`'s sun and moon track the machine's clock.
2. **The `weather` shader** overwrites the whole of `lens` with real sky —
   `(day frac, sunrise frac, sunset frac, cloud)` — when the LiveView has pushed
   `bc:sky`.

They do not corrupt each other today, because weather's branch runs second and
the widget never selects weather. **Both assumptions stop holding the moment the
widget's shader is a choice.** Specifically:

- Pick `weather` in the widget and it needs `bc:sky`, which is pushed per
  LiveView, not per canvas. Whether the widget's canvas receives it is unproven.
- Pick `daycycle` on the *homepage* and it gets no `data-daylight` at all, so the
  sun sits wherever `lens.x = 0` puts it. That is a broken-looking shader, not a
  refusal, which is the worst kind.

The second is the reason [D3](#d3--data-daylight-follows-the-shader-not-the-mount)
is not a detail.

---

## Part III — The decisions

### D1 — Which surface is this, exactly?

The shader is on the **Time & Place panel**, inside a card that has three tabs.
"The widget background" could mean either.

- **The panel** (recommended). It is where the shader is, the clock and
  conditions are designed to float over it, and Contacts and Notify are lists
  that a busy pattern would make harder to read. Smallest change, and honest:
  the surface is called Time & Place because that is what it backs.
- **The whole card.** More visually consistent, and it makes the widget feel like
  a single object — but it puts a shader behind two lists that were designed on a
  flat panel, and the operator would likely turn it off there immediately.

**DECIDED 08-15: the panel.** The surface is Time & Place. Contacts and Notify
keep the flat card they were drawn on, and the surface's label says what it
backs.

### D2 — Does `daycycle` join the catalog?

The widget's default has to be `daycycle`. Two ways:

- **Add it to `@builtin_shaders`** (recommended). It becomes selectable on all
  three surfaces, which is a feature — a day-cycle sky behind the terminal is a
  reasonable thing to want — and it keeps one catalog rather than a per-surface
  one. Requires D3, or it renders wrong everywhere but the widget.
- **Keep it out and special-case the widget's default.** Avoids touching the
  shared catalog, at the cost of a shader that exists, renders, and cannot be
  chosen — which is exactly the state `veil` was in and which
  `IMAGE_SHADER_ROADMAP` had to unpick.

**DECIDED 08-15: keep it out.** `daycycle` is the widget's default and is offered
nowhere.

> #### What that costs, measured rather than guessed
>
> This branch was scoped as the one that "avoids touching the shared catalog".
> **It does not — it needs two small mechanisms, and without the first the widget
> renders nothing at all.** Traced through the code after the decision:
>
> **1. The default would resolve to `:off`.** `resolve_mode/1` classifies the
> stored mode and falls back to `classify_default/1`, which classifies
> `config(surface).default` through the *same* `shader_selectable?/1` —
> `name in @builtin_shaders or (not a face and `Shaders.exists?(name)`)`.
> `daycycle` is in neither: it is bundled in the JS, so there is no
> `shaders/daycycle.wgsl` for `exists?/1` to find. `classify_default` returns
> `:unknown`, which becomes `:off`, and **the Time & Place panel goes blank.**
>
> The fix is a named list, not a bypass: bundled shaders a surface may *default*
> to but nobody may *pick*. One list, and the concept is exactly what this
> decision asked for — "renderable, not offered" — rather than a hole punched in
> validation that the next reader has to reverse-engineer.
>
> **2. There is no way back.** With `daycycle` absent from the catalog, an
> operator who picks `waves` has no row to click to undo it, and neither has the
> model. So the widget needs a **"Use default"** affordance — the same words and
> the same shape `BrandSlots` already uses when a slot is not on its default —
> and `background_set` needs to accept `"default"` as a mode.
>
> Making `"default"` a mode for **all three** surfaces rather than a widget
> special case: it is one grammar token, it means the same thing everywhere
> ("clear the stored choice"), and a surface-specific verb is the kind of thing
> that reads as an accident later. It also gives the model an honest way to undo
> a background change it made, which it does not currently have for any surface.

### D3 — `data-daylight` follows the **shader**, not the mount

Not really an open question, but it must be written down because the current code
says the opposite.

Today the flag is a property of *where the canvas is mounted* (the widget sets
it; nothing else does). It should be a property of *which shader is running*:
`daycycle` needs a clock, and nothing else reads `lens.x` that way. Derive it in
`ShaderCanvas` from `bg.shader`, and the widget stops being special.

**Test it by the failure it prevents:** select `daycycle` on the homepage and the
sun must move. Before this change it will not, and nothing will say so.

### D4 — Images behind a small card

The other two surfaces are large. This one is a ~300px card with a clock, a
temperature and a conditions line on top of it, under a scanline overlay.

An arbitrary photograph will make some of that unreadable, and the app cannot
know which. Two honest options: allow images and let the operator judge (the
existing posture everywhere else), or allow only `image:<slot>+<shader>` here so
something is always compositing over the picture. **Recommend the former** —
treating the operator as unable to see their own screen is the wrong instinct,
and the fix is one click.

### D5 — "Part of Pockets" is already true

Worth stating so nobody builds a second thing. The image pool **is** a Pocket
today: `pockets/backgrounds/`, fixed name, shared by both surfaces, filled in
Settings → Appearance. A third surface drawing from it needs **no new Pocket and
no new upload path** — it selects from the same pool.

A separate `pockets/widget-backgrounds/` would be the wrong shape: it would split
one pool into two for no reason the operator asked for, and the whole point of
`Appearance.options/0` is that there is one catalog and surfaces point at it.

---

## Part IV — The phases

### Phase 0 — Decompose `home_widget.ex` *(blocking, and not optional)*

699 lines, `FROZEN`. Nothing else here can land without touching it.

The seams are visible from its own structure: `place_panel/1` (the clock, the
sky, the conditions), the notify panel with its seven-segment countdown, and the
contacts/trusted list. Those are three features sharing a file because they share
a card.

**Exit:** `home_widget.ex` is a rail and a dispatch — the shape
`explained_panel.ex` is cited for — with the three panels as siblings, and the
gate re-tiered from `FROZEN` to `HELD` in the same commit that earns it.

**✅ DONE 08-15, on its own with no feature attached.** 699 -> 135 lines, three
siblings under `BusterClawWeb.Widget`. The cut was clean because the panels
shared no helpers — all five private helpers belonged to Notify — so the only
edits beyond moving lines were `defp` -> `def` and one call site in
`NotifyLive`, which renders the fired-notification modal.

**Verified as a move, not a rewrite:** the extracted text was diffed against the
original line ranges and is byte-identical apart from that rename, and the suite
was unchanged and green at the same count. A test was added for the thing a
decomposition can silently break — that each tab shows ITS OWN panel — and it was
broken two ways: wiring the dispatch to the wrong sibling (caught by LiveView's
duplicate-id check before the assertion even ran) and inverting one wrapper's
visibility.

### Phase 1 — The third surface

One entry in `Appearance.@surfaces`: `:widget`, keys
`widget_background_{mode,custom,colors}`, its own topic and message, label
`"Time & Place"`, default `"daycycle"`.

**Plus the two mechanisms D2 turned out to need**, and the first is not optional
— without it this phase ships a blank panel:

- a list of bundled shaders a surface may **default to but nobody may pick**, so
  `classify_default/1` stops resolving `daycycle` to `:off`;
- `"default"` as a mode for every surface, meaning "clear the stored choice", so
  there is a way back to the sky from both the picker and `background_set`.

Then follow the ripple in [I.5](#i5--one-table-drives-every-surface-and-a-third-entry-ripples) — the two `:for` sites in
`AppearanceLive`, `background_list`/`background_set`, the catalog descriptions,
and the tests that assert the pair.

**Exit:** `background_list` reports three surfaces and `background_set --json
'{"surface":"widget","mode":"waves"}'` is accepted and broadcast. **✅ DONE
08-15** — the *visible* half is Phase 2, which is the honest reading of this
exit: the data layer and the command surface are done, and the panel still
renders its hardcoded div until the next phase swaps it.

**The command layer needed no edit at all**, as its moduledoc promised: it
validates against `Appearance.surfaces/0`, so *"a surface added there is
reachable here the same day."* That claim was written before there was a third
surface and it held.

**One list was doing two jobs**, and separating them is most of this phase.
`@builtin_shaders` answered both "is this bundled in the JS?" (so it needs no
`/shaders/` URL and is not the operator's own work) and "is this offered?" (what
a picker shows, what `set_background/2` accepts). Those were the same set until a
default had to be renderable without being selectable. Now
`@default_only_shaders` holds `daycycle`, `@bundled_shaders` is the union, and
each call site was reclassified by which question it was asking.

**The predicted ripple landed in exactly one place**: `AppearanceLive`'s
`short_label/1`, which has a clause per surface and crashed on `:widget` — 62
tests, all the same cause. A missing clause is a crash rather than a fallback on
purpose, since a silent one would render a blank button nobody notices.

### Phase 2 — Render through `ShaderCanvas`

Replace the hardcoded div in `place_panel/1` with `<.shader_canvas>`, and give
`ShaderCanvas` the daylight derivation from [D3](#d3--data-daylight-follows-the-shader-not-the-mount).

Two things to get right, both already documented in that module:

- **Fold every new field into the remount key**, or the setting silently stops
  applying until a reload.
- The widget's canvas is small, and per
  [I.4b](#i4b--all-three-panels-are-always-in-the-dom-and-the-canvas-never-stops)
  it is live on **every** homepage render rather than only when Time & Place is
  showing. With the homepage background and any timer canvas that is three
  WebGPU devices at rest. Measure it; the cheap fix if it is bad is `:if` on the
  panel wrappers, which is what `PhoneComponent` already does.

**Exit:** the widget shows the operator's choice, and picking `daycycle` on the
homepage moves the sun.

### Phase 3 — The Appearance UI

`AppearanceLive` gains the third button per catalog row for free from the `:for`.
What is **not** free is that three buttons per row on a catalog of `off` + 5
built-ins + N workspace shaders + 8 image slots is a denser grid than the design
was drawn for.

**Exit:** the three-surface row reads clearly at the narrowest supported width,
and the surface labels say which is which without a legend.

### Phase 4 — The prose

`Explained.Shaders`, `Catalog.Appearance`'s two descriptions, and the Manual all
say "two surfaces". They become three. **This is not cleanup** — the same rule
this repo learned twice on 08-15: a document that describes a capability wrongly
is worse than one that omits it, and the model reads `INTRODUCTION.md`.

---

## Part V — Out of scope

- **A background behind Contacts and Notify.** That is D1's other branch; if it
  is wanted it is a separate decision, not a silent widening.
- **A per-surface palette for the widget.** The surface table already carries
  colours per surface, so this comes free if wanted — but it is not asked for and
  three palettes is three things to keep in tune.
- **`daycycle` reacting to real weather.** It reads the clock; `weather` reads
  the sky. Merging them is a shader change, not a surface change.
- **A fourth surface.** The split pane renders the terminal's background by
  design; it is not its own choice.

---

## Part VI — Risks

| Risk | Weight | Mitigation |
|---|---|---|
| Phase 0 is treated as "raise the cap once" | **High** | `FROZEN` means no headroom by definition; the gate header records two decompositions undone exactly this way |
| `daycycle` on the homepage renders wrong and says nothing | **High** | D3, and a test that asserts the daylight attribute follows the shader |
| Three WebGPU canvases on one page | Medium | measure in Phase 2; the fallback is that the widget's canvas is the one to drop |
| An image makes the clock unreadable | Low | D4 — visible instantly, one click to undo |
| The Appearance grid gets too dense at three buttons | Medium | Phase 3's exit is a width check, not a screenshot |

---

## Part VII — Open questions for the operator

**VII.1 — ANSWERED 08-15: the Time & Place panel.**

**VII.2 — ANSWERED 08-15: stay the default, offered nowhere.** See D2 for the two
mechanisms this turned out to need.

**VII.3 — STILL OPEN, and it is the only thing left. Is Phase 0 acceptable as the
price?** The feature is small and the
decomposition in front of it is not. The honest alternative is to say so and not
do this yet — which is a legitimate answer, and better than a raised `FROZEN`
cap.
