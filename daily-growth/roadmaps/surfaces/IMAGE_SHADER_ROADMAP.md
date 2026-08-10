# Image-reactive shaders — a pattern that reads the picture under it

**Scoped 08-09-26 · Status: Phases 1 and 2 SHIPPED. Phase 0 deferred (needs a
running app), Phase 3 next, Phase 4 is the skill.**

> ### Two scoped decisions were wrong, and the build found both
>
> Recorded here rather than quietly corrected, because each was wrong in a way
> that looked right on paper:
>
> - **[D3's marker](#d3--a-shader-declares-itself-image-reactive-by-sampling-not-by-its-name)
>   checked for `contentTex`, which a correct shader never contains.** A
>   workspace shader is the `fs_main` body alone — the binding lives in the
>   prelude, prepended in the browser — so the check would have matched *none*
>   of the shaders it was written to find.
> - **[Built-ins can't be scanned at all](#i8--smoke-has-a-dormant-content-path-which-is-why-built-ins-need-a-list)**,
>   because `smoke` carries a live sampling path from its Humo era. The scan
>   says image-reactive; the truth is it would draw the image nowhere.

> ### The one-sentence version
>
> **A background shader can sample the image the user selected, so the model can
> write one pattern that veils, warps and re-colours *whatever picture is
> underneath it* — and it declares itself image-reactive by sampling, not by
> being named something.**

> ### The operator's ask, verbatim
>
> *"take an image and create a shader pattern that covers it with some
> transparency… teach our model to express the shader pattern to reflect the
> image."*
>
> Two halves. The first is a rendering feature. **The second is the durable
> half** — it is a skill, and it is the reason this is worth doing at all.
> [Part V](#part-v--the-phases) puts the skill last only because it needs the
> contract to describe.

> ### Read this before planning around it
>
> **Most of the plumbing already exists and has since the Humo era.** The
> content-texture binding, the sampler, and the `copyExternalImageToTexture`
> call are all in the tree, wired, and deliberately fed nothing. Part I is what
> was read out of that code, not what is proposed. Four of the seven findings
> mean this is smaller than it looks; two mean the obvious implementation is
> wrong.

---

## Contents

- [Part I — What the code already tells us](#part-i--what-the-code-already-tells-us)
- [Part II — Locked decisions](#part-ii--locked-decisions)
- [Part III — The prelude contract](#part-iii--the-prelude-contract)
- [Part IV — The aspect problem, which is the whole feature](#part-iv--the-aspect-problem-which-is-the-whole-feature)
- [Part V — The phases](#part-v--the-phases)
- [Part VI — What this does not solve](#part-vi--what-this-does-not-solve)
- [Part VII — Risks](#part-vii--risks)
- [Part VIII — Open questions for the operator](#part-viii--open-questions-for-the-operator)

---

## Part I — What the code already tells us

Seven findings. Four shrink the job. Two kill the obvious implementation. One is
a behaviour that will silently regress if nobody names it.

### I.1 — The shader can already see a texture. Every shader. Today.

The shared prelude declares the sampler and the content texture on every shader
that compiles, built-in or workspace-authored:

```wgsl
@group(0) @binding(1) var smp: sampler;
@group(0) @binding(2) var contentTex: texture_2d<f32>;
```
`assets/js/smoke/prelude.wgsl.js:21`

Backgrounds never sample it. A `touch()` helper exists purely to keep bindings
1 and 2 alive in the `layout:"auto"` pipeline at "~zero cost" — the prelude's own
comment. **The binding is in scope for every shader the model has ever written
here.** A shader that samples it compiles today; it just reads an empty texture.

### I.2 — The upload call is already written, and the texture already carries the flag it needs

`smoke.js:123` already accepts `contentSource` / `contentDirty` and does:

```js
if (contentDirty && contentSource) {
  device.queue.copyExternalImageToTexture(
    {source: contentSource}, {texture: contentTex}, [contentWidth, contentHeight])
}
```

And the texture is created **with `RENDER_ATTACHMENT`**, carrying this comment:

> *"Content texture — the shader samples it, but for the background it is never
> written (kept tiny). RENDER_ATTACHMENT is kept because
> copyExternalImageToTexture (unused here) would require it."*
> `smoke.js:85`

Both background hooks then hardcode the gate shut — `contentDirty: false` at
`smoke_background.js:187` and `shader_preview.js:87`.

**Somebody left this door open on purpose.** The renderer is already general;
the two callers are what decline it.

### I.3 — The canvas is opaque, and (given D1) it can stay that way

`ctx.configure({device, format, alphaMode: "opaque"})` at `smoke.js:61`, with a
`clearValue` of `a: 1` at `smoke.js:143`. Nothing behind the canvas can show
through it.

That reads like the blocker for *"covers it with some transparency"*. It is not
— see [D1](#d1--the-shader-composites-the-image-itself-the-canvas-stays-opaque).
Sampling makes the alpha change unnecessary, which is worth a lot: `alphaMode` is
global to every shader on both surfaces, and changing it is a change nothing in
the suite currently asserts.

### I.4 — A background is an image **or** a shader, and that is one stored string

`Appearance.background/1` returns `kind: :none | :shader | :image` (`appearance.ex:246`),
resolved from a single Settings value that `classify/1` parses as
`"off"` | `<shader-name>` | `"image:<n>"` (`appearance.ex:330`).

There is no representation for "this image, with that shader over it". **This is
the actual Elixir work**, and it is pleasantly contained: `classify/1` is the one
parse site and `option_key/1` its stated inverse.

### I.5 — The terminal already composites an image under a shader canvas — in CSS

This surprised me and it changes the terminal half of the design.
`terminal_live.ex:342` paints the image as a **CSS `background-image` on the
terminal host**, while the shader canvas (`ic-shader-fill`) sits over it, and
`terminal_background_source/2` returns `"host"` or `"shader"` to tell xterm which
layer is painting.

So the terminal has had image-under-shader layering all along. The two are kept
mutually exclusive by I.4, not by the renderer.

### I.6 — …and the terminal's split continuity is CSS-owned, so it does **not** survive the move

The same block carries this:

> *"The JS anchors it to the viewport (`background-attachment: fixed`), so two
> joined terminals reveal adjacent slices of the same picture — one continuous
> image across the split."* `terminal_live.ex:338`

`background-attachment: fixed` is doing real work there. Move the image into the
shader and each pane samples the **whole** image into its own canvas: two joined
terminals would show two complete copies instead of one continuous picture.

**Nothing in the suite asserts this.** It is a look, and it would break quietly,
which is exactly the shape of regression this repo keeps writing summaries about.
Phase 0 measures it; [D6](#d6--the-shader-is-told-where-its-canvas-sits-on-screen) fixes it.

### I.8 — `smoke` has a dormant content path, which is why built-ins need a list

*(Found while building Phase 1; the JS test caught it on its first run.)*

`smoke.wgsl.js` predates the prelude, declares its own `struct U` and bindings,
and **still samples `contentTex` for real** — the leftover Humo reading surface,
which `smoke.js:8` admits to in a comment. It is inert only because the path is
gated on `reveal`, which every background hook holds at 0.

So a text scan reports `smoke` as image-reactive, and pairing it with an image
would render the image **nowhere** — the worst available outcome, because the
mode would look accepted.

**Which splits the rule in two, permanently:**

| | How "does it sample?" is answered | Why |
|---|---|---|
| **Workspace** shader | Scanned, exactly | It is an `fs_main` body alone — no bindings, no history, nothing to misread |
| **Built-in** shader | A declared list | A whole shader with a past. Text can say a shader *can* sample; only a person can say it would mean anything |

The list is `IMAGE_REACTIVE_BUILTINS` in `assets/js/smoke/shaders.js`, paired
with `Appearance.@builtin_image_shaders` and asserted in `appearance_test.exs`
(the Elixir side reads the JS file) — the `TerminalThemeTest` pattern, for the
same reason: a list that exists in two languages and is kept in step by a comment
is the exact drift this repo booked a whole roadmap for on 08-09.

`prelude.test.js` also pins smoke's dormant path explicitly, so if that `reveal`
gate ever goes, "image + smoke" becomes a **decision** at a failing test rather
than a discovery in the field.

### I.9 — The uniform layout was described in three places, all three stale

Before this roadmap touched anything: `params.js` said *"six vec4 = 24 floats =
96 bytes"*, `smoke.wgsl.js` said *"five vec4 = 20 floats = 80 bytes"*, and the
struct actually had **nine**. Nothing asserted any of it.

Phase 1 fixed all three and added the assertion that keeps them honest — the
struct's field count × 4 must equal `UNIFORM_FLOATS`. Without it, adding a field
to the struct without growing the buffer is a GPU validation failure at runtime,
on whichever surface is unlucky.

### I.7 — Some shaders render at 0.6 density and a 820px cap

`fitCanvas` (`smoke_background.js:199`) gives `mandel` `{density: 0.6, maxDim: 820}`
and `weather` `{density: dpr * 0.85, maxDim: 1400}`; custom shaders get full
density and no cap. The `shader-designer` skill already warns authors that
customs pay full price.

A shader that samples a photograph at 0.6 density **shows it soft**, and the
author will read that as their own bug. The skill has to say so.

---

## Part II — Locked decisions

### D1 — The shader composites the image itself. The canvas stays opaque.

The image is uploaded into `contentTex`; the shader samples it and returns the
blend it wants, fully opaque:

```wgsl
return vec4<f32>(mix(image_rgb, pattern_rgb, veil), 1.0);
```

Rejected: making the canvas transparent and letting a CSS image show through.
Three reasons, in order of weight:

1. **It cannot satisfy the ask.** A CSS-layered image is invisible to the shader,
   so the pattern cannot *reflect* it — only sit on it. The operator asked for
   reflection, and picked sampling explicitly.
2. `alphaMode` is global to every shader, both surfaces, the preview and the
   contact shaderfaces. This feature should not be the thing that changes how
   `smoke` composites.
3. In-shader gives strictly more range: the veil can vary per pixel — thicker over
   highlights, thinner over faces, driven by the image's own luminance. A single
   CSS opacity is one number for the whole frame.

**Consequence to state plainly:** "transparency" here is a *look*, not a
compositing mode. Nothing behind the canvas is ever visible. If a future feature
genuinely needs the DOM to show through, that is the `alphaMode` change and it is
a separate roadmap.

### D2 — The prelude supplies the image helpers. No shader does its own aspect math.

See [Part IV](#part-iv--the-aspect-problem-which-is-the-whole-feature). This is
the single highest-leverage decision in the document: the difference between a
model that can write these reliably and one that writes a subtly-stretched image
every time and cannot tell.

### D3 — A shader declares itself image-reactive by sampling, not by its name

`Shaders.face?/1` uses a name rule — `face` as a dash-separated word — because
nothing in a WGSL file distinguishes a face from a background.

**Here something does.** A shader is image-reactive if and only if its source
calls the prelude's image API.

> **Corrected while building.** This decision originally read
> `String.contains?(wgsl, "contentTex")` — **which would have matched nothing.**
> A workspace shader is the `fs_main` body alone; the binding
> (`@binding(2) var contentTex`) lives in the prelude and is prepended in the
> browser. A correctly-written image-reactive shader reaches the texture through
> `img()` and never writes `contentTex` anywhere. The marker has to match the
> **calls**.

As shipped, in `BusterClaw.Shaders`:

```elixir
@image_api_re ~r/\b(?:img|img_uv|img_lum|has_img)\s*\(|textureSample\w*\s*\(\s*contentTex/
```

The `\b` is load-bearing — without it a shader's own `myimg(...)` reads as
`img(`, and a pattern that never touches the image gets offered as
image-reactive. (Verified by breaking it: the decoy test is the only one that
fails.) The second alternative still catches an author who bypasses the helpers
— wrong, but honestly image-reactive — while ignoring a bare *declaration* of
the binding.

Derived from what the file *does*, never from what it is called, and it cannot
drift out of step with the file the way a naming convention can. **For built-ins
this does not hold** — see [I.8](#i8--smoke-has-a-dormant-content-path-which-is-why-built-ins-need-a-list).

This is the same instinct as the Pockets art states, which are derived from a
directory listing on read so there is no repair action to build.

**What it buys:** the picker can offer "image + shader" only for shaders that
would actually use the image, and a non-sampling shader picked into that mode is
refused at the source rather than rendering an unchanged pattern over an image the
user was told it would react to.

### D4 — One new mode string, parsed in the one place modes are parsed

`"image:<n>+<shader>"` — e.g. `image:2+ember-drift`. Extends `classify/1`
(`appearance.ex:330`) and `option_key/1`, and resolves to a fourth kind:

```elixir
%{kind: :image_shader, mode: "image", shader: name, source_url: ..., image_url: ..., slot: n}
```

Both halves are verified independently on resolve, matching the existing
staleness rule: a cleared slot **or** a deleted shader file **or** a shader that
no longer samples degrades to the surface default rather than rendering half the
thing. That last clause matters — a shader can stop sampling by being edited, so
this is not a write-time check.

### D5 — Still no commands. The model proposes; the human selects.

Unchanged, and this feature does not owe the argument `TERMINAL_PAINT_ROADMAP`
had to make, because it takes no new ground:

- The model already authors `shaders/*.wgsl` — "operator- and agent-editable,
  exactly like skills and jobs" (`shaders.ex:13`).
- The image is chosen by the operator, from the operator's own pool, by clicking.
- Selecting the combined mode is a human click in Settings → Appearance.

**On the image being visible to a shader:** there is no readback path in this
pipeline. The fragment shader writes to the canvas and nowhere else — no
`copyTextureToBuffer`, no `mapAsync`, no `readPixels`. And the point is moot in
the direction that matters: the model can already open the PNG in the workspace
with vision. Sampling gives the *shader* the pixels, not the model.

### D6 — The shader is told where its canvas sits on screen

The fix for [I.6](#i6-and-the-terminals-split-continuity-is-css-owned-so-it-does-not-survive-the-move):
feed each canvas's viewport rect into a spare uniform slot so a pane can sample
its own slice of the picture. `u.res.zw` is padding today (`params.js:15`), and
`u.style.w` (`u[19]`) and `u.mood.w` (`u[15]`) are free.

The prelude's `img_uv()` folds this in, so **an author writes nothing to get
split continuity** — they call the helper and it is correct in one pane or four.
A shader that ignores the helper gets per-pane repeat, which is a legitimate look,
just not the default.

### D7 — The veil is the shader's business, not a setting

No global "overlay opacity" slider. The mix amount is written into the shader by
its author, because the whole value of sampling is that the amount can *vary per
pixel*, and a slider that multiplies it would flatten exactly the thing the
feature is for. The existing custom-palette controls (`colA/B/C`) remain the
user's tuning surface.

Revisit trigger: an operator asking for the same shader at two strengths.

---

## Part III — The prelude contract

Added to `prelude.wgsl.js`, and therefore free to every shader:

| Helper | Returns | What it is for |
|---|---|---|
| `img_uv(uv)` | `vec2<f32>` | The canvas uv mapped into image space — **cover-fit, aspect-correct, split-aware**. Always call this before sampling. |
| `img(uv)` | `vec4<f32>` | `textureSample(contentTex, smp, img_uv(uv))`. The one-liner most shaders want. |
| `img_lum(uv)` | `f32` | Rec.709 luminance of `img(uv)`. The most common field to drive a pattern with. |
| `has_img()` | `f32` | `1.0` when an image is bound, `0.0` otherwise. Lets one shader work in both modes. |

`touch()` stays exactly as it is — it is what keeps a *non*-sampling shader's
bindings alive, and every shipped shader calls it.

New uniforms, all in existing padding (no buffer resize, no `UNIFORM_FLOATS` change):

| Slot | Was | Becomes |
|---|---|---|
| `u.res.z` / `u.res.w` (`u[2]`, `u[3]`) | pad | image pixel width / height (`0` = no image) |
| `u.style.w` (`u[19]`) | pad | canvas viewport offset+scale packed for `img_uv` (see D6) |

**`has_img()` reading `u.res.z > 0` is the load-bearing detail:** it means an
image-reactive shader degrades to a plain pattern when selected without an image,
rather than sampling black and rendering a dead rectangle. The skill will require
authors to handle it, and Phase 1 ships a shipped-shader example proving it.

---

## Part IV — The aspect problem, which is the whole feature

**A naive `textureSample(contentTex, smp, uv)` is wrong every single time.**

The canvas is whatever shape the window is. The image is whatever shape the
photograph is. Sampling canvas-uv directly stretches the picture to the window —
subtly on a near-match, grotesquely on a portrait photo in a wide terminal. And
it is the kind of wrong that looks *fine* while you are writing it, because a
test pattern has no aspect and a face does.

Three further traps, all of which a shader author hits and none of which are
obvious:

1. **The uv origin is bottom-left.** The prelude's `vs_main` emits
   `uv = pos.xy * 0.5 + 0.5` (`prelude.wgsl.js:35`), so the image samples
   **vertically flipped** unless the helper corrects it. Nothing in the current
   contract makes this visible, because no background samples anything.
2. **The canvas is not the window.** `fitCanvas` applies a device-pixel density
   and a per-shader cap (I.7), so `u.res` is not CSS pixels and cannot be used
   raw for layout-relative math.
3. **Two joined terminals are two canvases** showing one picture (I.6).

**Which is why the aspect math lives in the prelude and not in a doc paragraph.**
If `img_uv()` is a helper, an author writes `img(in.uv)` and is correct. If it is
advice in the skill, every shader re-derives it, most get it close enough to look
plausible, and the failure is a slightly-squashed photograph nobody can name.

That is the same argument `grad3` already won — the skill says *"use them, don't
re-roll"* about noise and palettes for exactly this reason.

---

## Part V — The phases

### Phase 0 — Prove an image reaches a shader, and measure the split — **DEFERRED**

Deferred, not skipped: it needs a running app with WebGPU in the webview, which
is the operator's to run. Phases 1 and 2 were buildable without it because
neither touches the GPU upload path — the contract and the mode are both
assertable on the ground. **Phase 3 cannot start until these four are answered**,
and its first commit should carry them.

A spike, not a feature. Hardcode one image into the homepage background hook,
sample it in a throwaway shader, and answer four questions with a running app:

- Does `copyExternalImageToTexture` work against this texture as created, or does
  it need usage flags beyond the three already set?
- What does the sized-to-image texture cost on resize — is a re-upload per resize
  acceptable, or must the texture be allocated once at image dimensions?
- **What do two joined terminals actually do** with a sampled image (I.6)? Confirm
  the break before designing D6's fix around it.
- Does an image-sampling shader at `mandel`'s 0.6 density read as soft enough to
  matter (I.7)?

Exit: the four answers written into this document. Delete the spike.

### Phase 1 — The prelude contract — **SHIPPED**

`has_img` / `img_uv` / `img` / `img_lum` in `prelude.wgsl.js`; `struct U` grew two
appended vec4s (`imgSize`, `imgRect`); `UNIFORM_FLOATS` 36 → 44 with the packing
in `params.js`. **`veil`** is the worked example — `assets/js/smoke/veil.wgsl.js`,
registered in `shaders.js` and given a palette.

**`veil` is deliberately NOT in `Appearance.@builtin_shaders`.** Being in the JS
registry is not the same as being offered: `face`/`sevenseg`/`keypad` have always
been there without being background options. It joins the picker in Phase 3, when
a surface can actually feed it an image — shipping it selectable now would put a
pattern in the picker whose whole point does nothing.

New guard: **`prelude.test.js`**, which asserts things nothing in this repo had
asserted about the prelude — the struct's field count against `UNIFORM_FLOATS`,
the image slots being *last* (append-only), and `smoke`'s private struct copy
staying a **prefix** of the prelude's. It is allowed to be shorter; it is not
allowed to differ, because a field inserted mid-struct shifts every offset after
it and feeds that shader silently wrong numbers.

Also pinned there, because each is a trap an author cannot see: `img_uv` guards
the zero-size case rather than dividing by it (0/0 is NaN, and a NaN uv samples
black across the *whole frame* — so "no image" would look like catastrophic
failure instead of a graceful degrade), it flips Y, and `img` uses
`textureSampleLevel` so it is legal inside a branch.

### Phase 2 — The combined mode — **SHIPPED**

`Shaders.samples_image?/1` (the corrected marker, D3), `Appearance.samples_image?/1`
layering built-ins over it, the `"image:<n>+<shader>"` parse in `classify/1`, the
`:image_shader` kind, and `option_key/1`'s inverse. Three-way staleness per D4,
each with its own test — including the one a write-time check could not catch: a
shader **edited to stop sampling** after it was selected.

`set_background/2` grew a third error, `:not_image_reactive`, distinct from
`:invalid_mode` on purpose — the shader is real and selectable, it just would not
react, and accepting it silently is the exact failure this mode exists to prevent.

**Not yet reachable from the UI**, by construction: every consumer keys on `kind`,
and none of them knows `:image_shader` until Phase 3.

### Phase 3 — The two surfaces and the preview

Homepage (`home_widget.ex`), terminal (`terminal_live.ex`), and the Appearance
preview. The picker offers the combined mode only for shaders that sample.

**Two cautions carried forward:**
- `home_widget.ex` is **FROZEN at 699** in the size gate — the new mode cannot
  land in it. It needs a component, or the phase owes a cut in the same commit.
- `appearance_live.ex` is **HELD at 1035** with its next cut already named. A new
  picker mode will cross it.

### Phase 4 — The skill

The durable half. See [Part VI](#part-vi--what-this-does-not-solve) for scope, and
the open question in VIII.1 on whether this extends `shader-designer` or becomes
its own file. What it must carry, gathered while building 1 and 2:

- The four helpers, and **why `img_uv` is not optional** (Part IV's three traps).
- `has_img()` degradation as a requirement, not a nicety.
- Composite opaque and return `alpha 1.0` — the canvas is opaque, so a fractional
  alpha asks for a blend that will never come.
- **Sample once and reuse.** `img()` and `img_lum()` are each a fetch.
- The density tiers ([I.7](#i7--some-shaders-render-at-06-density-and-a-820px-cap)) —
  a photo sampled at 0.6 reads soft, and the author will blame their own shader.
- Point at `veil` as the worked example rather than re-explaining it.

**One correction the skill owes independently of this feature.** It documents
`touch()` as *"an interaction signal"* and its example does
`col = col + vec3<f32>(touch()); // optional interaction lift`. **`touch()` always
returns exactly 0** (`textureSampleLevel(...).a * 0.0`) — it is a bind-group
layout keeper and nothing else. Every shader written from that skill carries a
line its author believes does something. Fix it in the same pass; the prelude's
own comment was corrected in Phase 1.

### Phase 5 — Open space

Deliberately empty. Candidates with triggers, none built speculatively:
a second veil strength (D7's trigger), image-reactive shaderfaces on `/phone`
(trigger: an operator asking), palette *extraction* from the image so `colA/B/C`
default to its dominant colours (trigger: authors hand-tuning palettes to match
photos more than once).

---

## Part VI — What this does not solve

- **The model still cannot select a background.** By design (D5). It writes a file
  and tells the operator its name, exactly as today.
- **The model does not choose the image.** One shader must work over any picture.
  This is a *feature* — it is why the pattern adapts — but it means the model
  cannot tune a shader to one photograph unless the operator asks it to look at
  that file, which is a vision read, not a rendering path.
- **No DOM shows through the canvas** (D1). "Transparency" is a look here.
- **No palette extraction.** The image drives *structure* via sampling; the colours
  still come from `colA/B/C`. Phase 5 candidate.
- **Nothing is asserted about how it looks.** As with every shader in this app, the
  only real verification is a build and a person looking — a `LAUNCH` **G-40**
  entry, listed in VIII.

---

## Part VII — Risks

| Risk | Why it bites | Mitigation |
|---|---|---|
| A stretched image reads as "fine" | Aspect error is invisible without a reference | The math is a prelude helper, not advice (Part IV) |
| Split terminals silently stop being continuous | It is a look; nothing asserts it | Phase 0 measures it; D6 fixes it; a walk confirms it |
| A shader stops sampling after an edit and the mode lies | `samples_image?` at write time would go stale | Checked on resolve, not on write (D4) |
| `home_widget.ex` is frozen | The gate fails the build, correctly | Phase 3 owes a component or a cut |
| Sampling a photo at 0.6 density looks soft | Author reads it as their own bug | I.7 goes in the skill, with the density tiers named |
| The uv flip | Bottom-left origin; image lands upside down | Corrected inside `img_uv`, and stated in the skill anyway |

---

## Part VIII — Open questions for the operator

### VIII.1 — Does this extend `shader-designer`, or become its own skill?

`shader-designer.md` is 108 lines and already carries the full prelude contract.
Image sampling adds the four helpers, the aspect trap, the `has_img()`
degradation rule, and the density caution — call it +40 lines.

**My read: extend it.** An image-reactive shader is a shader; a second file would
duplicate the prelude contract, and this repo has written the "list existed twice,
kept in step by a comment" summary once already this week. But a separate
`image-shader` skill is defensible if you want the model to reach for it by name.

### VIII.2 — Should the homepage's combined mode respect the chat panel?

The homepage chat sits over the background in a translucent blurred panel. An
image-reactive shader will be busier than `smoke` — that is the point — and
busy-under-blurred can hurt reading.

Options: leave it to the author (consistent with D7), or have the prelude expose
the panel rect so a shader can calm itself under it. **The second is a real
feature and probably its own phase**, so I have not scoped it.

### VIII.3 — G-40 walk, or its own?

The acceptance here is "a build and a person looking": an image + shader on both
surfaces, a portrait photo in a wide window, two joined terminals, and a shader
selected with no image (the `has_img()` degradation). Four sittings, or one G-40
line?
