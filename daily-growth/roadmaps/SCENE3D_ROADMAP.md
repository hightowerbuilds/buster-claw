# Scene3D — a 3D card the model can put in the chat

**Scoped 08-08-26 · Status: SCOPED, not started.**

**What this is, in one line:** a second visual channel for the homepage chat where
the model emits a **declarative 3D scene** — never code — which our renderer
projects into an inline card in the transcript.

**Why it fits here:** the app already has every substrate this needs. A fenced-block
channel from assistant text (`SvgViewer`), a server-side SVG doctrine with a
worked example (`PortfolioChart`), a validated palette convention (Chart Builder),
a runtime-loadable skill mechanism for teaching authoring (`shader-designer`), and
a live-compiled WebGPU pipeline (`assets/js/smoke/`). Most of this roadmap is
assembly. The one genuinely new thing is a **scene vocabulary**, and that is the
part most likely to be wrong — which is why Phase 0 builds it alone.

---

## The lay of the land (read before building)

**The fenced-block channel is a well-trodden path.** `BusterClaw.SvgViewer` is the
template: `extract/1` (fail-closed, 100 KB cap, document order), `sanitize/1`,
`normalize/1`, `guide/0` (the system-prompt appendix). It is wired into
`StatusLive` at exactly four points — `append_system_prompt` (`status_live.ex:664`),
live extraction (`:973`), sanitize-on-collect (`:1169`), and re-extraction on
history load (`:1214`). **Copy this shape; do not invent a second one.**

**Persistence is free, and it works by a specific trick.** Assistant rows are
stored in the transcript with their fences *intact*, and `load_chat_history/2`
re-extracts them on mount (`status_live.ex:1214`). That is why drawings survive
reload and tab-switch without a table. A `scene3d` block gets the same behaviour
for free — but only if it is stored raw and re-parsed, not pre-rendered.

**There is no persistent SVG viewer, and the moduledoc says so.** `chat_panel.ex:518`:
*"There is no persistent viewer — a drawing lives in the transcript as a 'View
drawing' link on its message, which opens this modal."* The bubble renders a
button (`chat_panel.ex:531`), the modal renders `Phoenix.HTML.raw/1` of the
sanitized SVG (`:345`), and `@max_chat_svgs 200` caps the session pool
(`status_live.ex:27`). **An inline card is therefore new UI, not reuse.** This is
the single biggest scoping correction in this document.

**The house SVG doctrine is already written down.** `PortfolioChart`'s moduledoc:
*"Server-rendered SVG. No charting dependency: the data already lives on the
server, LiveView already re-renders, and the CSP forbids fetching a library
anyway."* The operator declined `lightweight-charts` on 07-28. The same reasoning
forecloses three.js here, independently of the WebGPU argument below.

**The model already authors GPU code — and that is *not* the model to copy.**
`BusterClaw.Shaders` lets the agent write `<workspace>/shaders/<name>.wgsl`
(64 KB cap, must define `fs_main`), served at `GET /shaders/:name` and compiled
live in the webview. It is safe because WGSL runs in the WebGPU sandbox with no
memory or IO escape, and because **a shader only renders when the user selects
it** — an author can propose a pattern, never force it onto the screen. A chat
card has no such gate: it renders the moment the model emits it. That difference
is why the shader channel's permissiveness does not transfer.

**The WKWebView constraint is measured, not theoretical.** `assets/js/smoke/smoke.js:1-6`:
one pipeline, one fullscreen triangle, a uniform buffer and a texture — *"no
second pipeline, no storage buffer; that combination once crashed the GPU
process."* A conventional mesh renderer (vertex buffers, depth attachment, a
pipeline per material) is precisely the shape that crashed it.

**And GPU 3D was already attempted here once, and abandoned.** The Humo work
(07-04) tried drawing into the shader with SDFs; **the SDF attempt crashed
WKWebView**, and the collapse to "smoke as backdrop, SVG shown as SVG" is the
result. This roadmap's entire structure — CPU projection to SVG first, GPU as a
gated maybe — is downstream of that. See the Phase 4 banner.

**Canvas was evaluated and rejected, and the reason generalises.**
`archive/08-03-26-chart-builder-roadmap.md` Part II: *"Canvas cannot be authored
declaratively... 'the model draws a canvas chart' means the model produces
executable JavaScript."* That verdict is about **model-authored executable code**,
not about pixels. It binds this feature too.

**The palette convention exists and was reconciled against the `dataviz` method**
(Chart Builder Phase 3, `9c12d24`): a validated 5-slot palette, snap-to-passing
against the app ground. Scene colours are indices into it.

---

# Part I — The design question, answered

**Decide nothing else until this is agreed.**

### What was ruled out, and why

**(A) Vendor three.js (or write a WebGPU mesh renderer).** Rejected on two
independent grounds: the CSP forbids fetching a library and the house doctrine
forbids adding one, *and* a multi-pipeline depth-buffered renderer is the exact
configuration recorded as crashing the WKWebView GPU process. Either alone is
disqualifying.

**(B) The model authors WGSL per card.** Tempting, because the raymarch pattern
satisfies the one-pipeline constraint by construction and the agent already
writes shaders. Rejected as an **authoring** channel: WGSL authoring reliability
is far below JSON authoring, a compile failure yields a blank card with no
recourse mid-conversation, and — per the lay of the land — the existing shader
channel is safe partly *because the user selects it*, which a chat card cannot
replicate.

**(C) 3D in Elixir proper.** There is nothing to build on. `:gl`/`:wx` ship with
OTP (`erlang/28.4.2/lib/wx-2.5.4/`) but render into a wx desktop window, not the
webview. Scenic is 2D and owns its own window. Nx is tensor compute, not
rasterization. No three.js equivalent exists on Hex. **This is not a mark against
Elixir**: the webview draws no matter what feeds it, and Elixir has never been on
this app's drawing path.

### What we are building: one vocabulary, two renderers

The model only ever emits **`scene3d` JSON**. That one validated scene drives:

1. **an SVG projection** — Phase 1, always available, the fallback; and
2. **a raymarched WGSL render** — Phase 4, gated, strictly optional.

The primitive set below (box, sphere, cylinder, plane, capsule) is exactly the set
signed distance functions are best at, so the second renderer is a *different
backend for the same data*, not a second feature. Crucially, its shader is **our
code parameterized by a uniform buffer** — the model never writes WGSL, so
verdict (B) and the canvas rejection both stay intact.

---

## Decisions taken while scoping (revisit if wrong)

1. **JSON, not a DSL.** The model emits JSON reliably and `Jason` is already a
   dep (`mix.exs:106`). A DSL is a parser I would have to write and the model
   would trip over.
2. **The camera is two orbit angles, not eye/target vectors.** Models get
   look-at matrices wrong constantly; azimuth + elevation is nearly impossible to
   get wrong and always frames *something*.
3. **Auto-framing is mandatory.** We compute the scene's bounding box and fit the
   camera to it. The model never specifies zoom, and a scene authored at scale
   0.01 or 1000 both render correctly. **This single decision kills the most
   common failure mode**; do not make framing the model's job.
4. **Colours are palette indices, not hex.** Reuses the Chart Builder's validated
   5-slot palette. Every card stays on-brand and legible in both themes, and the
   model cannot pick an unreadable grey.
5. **Labels are first-class and billboard.** This is a tool for expressing an
   idea, not for making art — an unlabeled box communicates nothing. Labels draw
   *after* all geometry so they are never occluded.
6. **Composition helpers (`grid`, `stack`, `ring`) over more primitives.** "Nine
   servers in a 3×3" is one node and the model does no arithmetic. This is where
   expressiveness comes from; each new *primitive* is tessellation code plus a
   new way to be wrong.
7. **Painter's algorithm, and the limitation is documented rather than solved.**
   Sort faces by centroid depth, cull backfaces. This is wrong for
   interpenetrating solids. The guide forbids intersecting geometry; if the model
   does it anyway the artifact is visible and accepted. **Do not build a BSP
   tree for a chat card.** Record it in the moduledoc so it is not refiled as a
   bug later.
8. **The card renders inline, and that is new UI.** Per the lay of the land, SVG
   is link-and-modal. A scene renders as a bordered card in the bubble, and
   *also* opens the existing modal on click. Reuse `svg_modal/1` for the zoom
   path; the inline card is the new part.

---

## Open questions

### Two drawing channels, one system prompt — the real risk

`SvgViewer.guide()` is already appended to the homepage chat
(`status_live.ex:664`). Adding a second visual guide means the model chooses on
every turn, and **the likely failure is not that it picks wrong — it is that it
uses neither well.**

Proposed line, to be written into both guides: **SVG for anything flat or
annotated; `scene3d` only when the third dimension carries real meaning** —
structure, layering, volume, spatial relationship. If a scene reads the same
flattened, it should have been SVG.

**Decide this empirically, not in the abstract.** Ship Phase 1, then read real
transcripts before starting Phase 2. If the model reaches for 3D decoratively,
tighten the guide before adding capability.

### Does the WGSL renderer survive its own constraint?

A raymarcher evaluates every primitive per pixel absent spatial acceleration, so
the realistic ceiling is **30–50 primitives**. Decision 6 pushes directly against
that — a 3×3×3 grid is 27 primitives on its own. Phase 4 therefore needs either a
primitive budget that falls back to SVG when exceeded, or acceleration work not
worth doing for a chat card. **This is the question that may kill Phase 4**, and
Phase 1 answers it for free by revealing how large real scenes actually get.

---

# Phase 0 — The vocabulary and its validator, with no renderer at all

*Deliberately shippable alone. This is the risky part; get it in front of the
operator before any pixels exist.*

- [ ] `BusterClaw.Scene3d` (`lib/buster_claw/scene3d.ex`): `extract/1` mirroring
  `SvgViewer.extract/1` (fenced ```` ```scene3d ````, fail-closed, byte cap —
  start at 32 KB, well under SVG's 100 KB since JSON is denser).
- [ ] `validate/1` → `{:ok, scene}` | `{:error, reason}`. Typed, total, and
  strict: unknown keys rejected, numbers finite and bounded, node count capped,
  nesting depth capped, palette index in range, label length capped.
- [ ] The vocabulary itself: `camera` (orbit angles only, per decision 2),
  `nodes` of `box` / `sphere` / `cylinder` / `plane` / `capsule` / `polyline` /
  `arrow`, each with `at` / `rotate` / `label` / `color`; plus the `grid` /
  `stack` / `ring` composition helpers of decision 6.
- [ ] `expand/1`: composition helpers → a flat primitive list. Pure, and the
  place the node cap is enforced *after* expansion (a small `grid` must not
  smuggle in 10,000 boxes).
- [ ] Tests: a valid scene round-trips; every malformed shape fails closed with a
  named reason; expansion is bounded; a hostile scene (huge counts, deep
  nesting, NaN/Infinity, absurd coordinates) is refused without a crash.

**Done when:** the vocabulary is expressible, the validator is total, and the
operator has read a handful of hand-written example scenes and agrees they read
naturally. **No rendering in this phase.**

# Phase 1 — Project to SVG, render an inline card

- [ ] `BusterClaw.Scene3d.Project`: camera basis from orbit angles, bounding-box
  auto-fit (decision 3), model→view→projection, backface cull, painter sort by
  face centroid (decision 7).
- [ ] Tessellation for each primitive. Keep segment counts low and fixed — a
  sphere at 16×8 is plenty for a chat card and keeps the polygon count sane.
- [ ] SVG emit: flat-filled polygons from the palette (decision 4), edge strokes,
  billboarded labels drawn last (decision 5). Labels are the **only**
  model-controlled text and must be HTML-escaped.
- [ ] Inline card in `chat_bubble/1` for `:assistant` (decision 8), plus reuse of
  `svg_modal/1` for click-to-zoom. Mirror the existing `svg_ids` assign shape so
  a message can carry several scenes.
- [ ] Wire into `StatusLive` at the same four points the SVG channel uses,
  including re-extraction in `load_chat_history/2` so scenes survive reload.
- [ ] `guide/0` — the system-prompt appendix, carrying the SVG-vs-3D line from
  the open question above. Update `SvgViewer.guide/0` with the same line.
- [ ] Tests: a scene in an assistant message renders a card; a malformed scene
  is dropped silently; scenes survive a history reload; a label containing
  `<script>` is escaped in the output.
- [ ] Operator eyeballs it in the real app (operator runs the server — agent
  tasks get SIGTERM'd, per `feedback_dev_server_run`).

**Done when:** the model can put a labeled 3D diagram in the chat, it survives
reload, and it looks right in a running app.

**Note the safety posture here, because it inverts the SVG channel's:** we
*generate* the SVG from validated numbers, so no model-authored markup ever
reaches the DOM and there is no sanitizer regex to outsmart. This channel is
strictly safer than the one it sits beside.

# Phase 2 — Make it look like something

*Gated on reading real Phase 1 transcripts first (see the open question).*

- [ ] Faceted shading from face normals against a fixed key light — the cheapest
  change with the largest legibility gain.
- [ ] Ground plane with a soft contact shadow; optional subtle grid.
- [ ] Label leader lines when a label would otherwise sit on top of geometry.
- [ ] Depth cue: slight desaturation with distance.

**Done when:** a scene reads as a solid object rather than a wireframe, without
any new model-facing vocabulary.

# Phase 3 — Orbit drag *(optional)*

- [ ] Port the projector to JS (~200 of the ~450 geometry lines) as a first-party
  module under `assets/js/lib/` with unit tests, per house convention
  (`assets/js/lib/*.test.js`).
- [ ] Hook that re-projects on pointer drag; the Elixir projector becomes the
  static/export path.
- [ ] A lockstep test pinning both implementations to the same projection for a
  fixture scene. **Per `feedback_sweep_renames`: the Elixir suite cannot see JS,
  so without this the two silently diverge.**

**Done when:** a card can be rotated by dragging, and the two projectors provably
agree.

**Honest cost:** this is the phase that duplicates the math. Only take it if
Phase 1 use shows people actually want to turn the scenes around.

# Phase 4 — The WGSL renderer *(gated; probably should not happen)*

> **Prior art: this was tried, and it crashed.** The Humo work (07-04) attempted
> to draw into the shader via SDFs and **the SDF attempt crashed WKWebView**. The
> conclusion recorded at the time was blunt — *"drawing into the shader was never
> honest... rasterizing an SVG into fog just hides a real SVG"* — and it is why
> the smoke became pure background and SVG is shown as SVG. That verdict was
> reached by the operator on this codebase, on this webview.
>
> **Read this before reopening the phase.** Two things are genuinely different
> now — the scene is *validated data* rather than freehand shader authoring, and
> the primitive budget below is a hard cap the earlier attempt did not have — but
> "different" is not "safe," and the burden of proof sits on this phase. If Phase
> 1 lands well, the honest default is that Phases 0–3 **are** the feature and
> this one stays closed.

*Do not start this until the open question about primitive count is answered by
real Phase 1 scenes, and not before re-reading the crash note above.*

- [ ] SDF raymarcher as **our** shader, parameterized by a uniform buffer of
  primitives. One pipeline, one fullscreen triangle — the `smoke.js` pattern,
  unchanged.
- [ ] Primitive budget with automatic fallback to the SVG render when exceeded.
- [ ] Labels as a DOM overlay positioned by the *same* camera math the projector
  already computes — raymarching cannot draw text.
- [ ] Blank-canvas fallback to SVG whenever WebGPU is absent, matching every
  other shader surface in the app.

**Done when:** the same scene JSON renders with real lighting on machines that
support it and identically-legibly on machines that don't.

---

## Tail items

- `SvgViewer`'s moduledoc cites `script-src 'self' 'nonce-…'` (`svg_viewer.ex:16`).
  The nonce was removed 08-03 (`content_security_policy.ex:25`). One-line doc fix;
  fold into Phase 1.
- If Phase 1 lands, consider whether the `shader-designer` skill should gain a
  sibling `scene-designer` **reference skill** rather than growing `guide/0`. The
  skills layer is runtime-loadable and operator-editable; a long guide in the
  system prompt is neither.
