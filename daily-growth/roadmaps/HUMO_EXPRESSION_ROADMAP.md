# Humo Expression — the agent's own drawing library

*2026-07-03. Builds on `HUMO_ROADMAP.md`. Supersedes and absorbs the earlier
narrow "Humo Draw" plan. The thesis, in Luke's words: **let Humo's agent convey
and express whatever it needs to** — mood, diagrams, retro pixel styles, freeform
drawing — through **our own in-app library**, not a bag of external dependencies.*

*Governing principle: **one expressive channel, one render substrate, one
home-grown vocabulary — and the agent composes it, never codes it.** The agent
emits small declarative blocks in its reply; BusterClaw parses, validates, and
renders them into the smoke. The vocabulary is ours: curated, tested, documented,
and shipped in-app (`assets/js/humo/`). Robust means comprehensive and reliable,
not a demo. Same stance as everything here — primitives the agent composes, the
intelligence remote, the surface auditable.*

Effort tags: **S** = a sitting, **M** = a day-ish, **L** = multi-day / has unknowns.

---

## Decisions locked (Luke, 07-03)
- **Destination: our own custom builder, kept in-app**, where **Claude can draw
  *anything* into Humo.** It lives in `assets/js/humo/`, not a separate repo
  (unlike `foreshadow`). **To bootstrap** we may lean on external libraries as
  references/seeds (iq's MIT SDFs, `wgsl-fns`, even Mermaid/thi.ng for ideas) —
  but every phase converges on *our* vocabulary; nothing external ships as a
  runtime dependency.
- **Diagrams: curated spec + our Canvas2D layout** (not Mermaid). Home-grown
  layout, smoke-native styling from the first pixel.
- **The drawing ability is a first-class, robust capability** — the centerpiece,
  not a toy.
- **Pixel / Game Boy style** is in scope: the agent can render in a retro
  quantized aesthetic.
- **"Express whatever it needs to"** ⇒ the channel is *extensible by block type*;
  new expression modes slot in without re-plumbing.

## The three layers

**1. The channel (shared, the foundation).** The agent emits fenced blocks in its
reply — ```` ```humo-<type> {json}``` ````. `HumoLive` parses them out of the
assistant stream, **strips them from the visible text** (they never show as raw
JSON), validates against the type's schema, and dispatches. One way in, every
mode rides it. Sentinel-audited; malformed blocks fail closed to plain text.

**2. The substrate (shared).** Two render targets, both already built in Humo:
- **The smoke uniforms** — modes that *dress* the smoke (mood, pixel/Game Boy
  render style) drive uniforms directly.
- **The content texture** — modes that produce *content* (diagrams, drawings)
  render to the offscreen content canvas/texture that already flows through the
  condense/dissolve/lens pipeline. A drawing condenses out of the fog and reads
  under the loupe **for free**.

**3. The library (the vocabulary — "our own"):**
- **Style/mood** — `energy` (drift + turbulence), `temperature` (cool ash ↔ warm
  ember, in-palette), `density`; plus **render modes**: normal, **gameboy**
  (spatial + palette quantization to the 4-shade DMG green).
- **Diagrams** — a curated element set (graph nodes/edges, UML class/sequence
  boxes) with our own Canvas2D layout, drawn in Industrial Claw.
- **Drawing (SDF)** — our curated WGSL SDF vocabulary (Inigo Quilez's **MIT** 2D
  distance functions, ported + attributed): primitives (circle, box, rounded-box,
  segment, triangle, polygon, hexagon, star, arc, ring) + operators (union,
  subtract, intersect, **smooth-union**, round, annular) + transforms (translate,
  rotate, scale, mirror, domain-repeat) + smoke-native fills. **This is the
  "robust drawing" centerpiece.**

## The outward survey (why we build our own)

The technique is **Signed Distance Fields**. The decisive constraint is licensing
(this *ships*): a non-commercial license is disqualifying.

| Source | License | Verdict |
|---|---|---|
| **iq — 2D distance functions** ([distfunctions2d](https://iquilezles.org/articles/distfunctions2d/)) | **MIT** (code) | ✅ Port into our library; attribute. The shape vocabulary. |
| iq — 3D distance functions | MIT (code) | ⚠️ Stretch only (3D raymarch = different surface). |
| **hg_sdf (Mercury)** ([site](https://mercury.sexy/hg_sdf/)) | **CC BY-NC** | ❌ Non-commercial — cannot ship. Ideas only. |
| **Shadertoy corpus** ([terms](https://www.shadertoy.com/terms)) | **CC BY-NC-SA** default | ❌ Don't lift. Reference only. |
| **koole/wgsl-fns** ([repo](https://github.com/koole/wgsl-fns)) | **MIT** | ✅ Seed (thin: circle/box). |
| @thi.ng/shader-ast(+stdlib) ([docs](https://docs.thi.ng/umbrella/shader-ast/)) | Apache-2.0 | ⚠️ Heavy dep, GLSL-target. Study the AST idea; don't adopt. |

**Conclusion:** no drop-in, shippable, WGSL 2D-SDF shape library exists — which is
*exactly why we build our own*. Small, curated, MIT-sourced, tested, in-app.

## Architecture forks (recommended; open for override)
- **SDF compile strategy — Path B (recommended): a fixed über-shader that
  *interprets* a bounded instruction buffer.** The agent fills a data structure;
  it never authors WGSL. Caps (max shapes/ops) are structural — the GPU-DoS and
  injection brakes come from the schema, not vigilance. (Path A, spec→WGSL
  codegen, stays a later power-user escalation.)
- **Delivery — the inline block** is the expressive path (the agent draws
  mid-reply); a command verb (`humo_*`) is the programmatic/headless path. Both,
  block first.

## Phases

### Phase 0 — The channel + first style facet *(foundation; build now)*
The shared expressive channel end-to-end, proven by the cheapest vivid facet:
**style** (mood + Game Boy pixel). `BusterClaw.Humo.Expression` parses/strips
```` ```humo-style``` ```` blocks; the smoke shader gains mood uniforms
(energy/temp/density) + a quantization render mode; Humo's agent is *taught* the
vocabulary via an appended system prompt. **(M)**
*Exit:* ask Humo's Claude to "answer in a calm cool tone" or "go Game Boy" and the
smoke changes — from the agent's own block, stripped from the text.
**SHIPPED 07-03.** The channel is live and generic across block types.
`BusterClaw.Humo.Expression.extract/1` pulls ```` ```humo-<type> {json}``` ````
blocks from the reply, decodes each, and returns the stripped text (fail-closed
on bad JSON); `HumoLive` dispatches `style` → `humo:style`, renders only clean
text. Shader gained `mood` (energy→drift/turbulence, temp→warm/cool white-balance,
density→thickness) + a `style` render mode (Game Boy: spatial pixel-quantize +
4-shade DMG palette), all neutral-preserving. `styleFromSpec`/`easeExpression`
(bun-tested) normalize + ease; per-reply styling resets to neutral each turn. The
agent is taught via `Humo.expression_guide/0`, appended to its system prompt
through a new opt-in `Chat` `:append_system_prompt` (shared engine, defaults off).
mix 786, bun 44. *Channel is now the rail Phases 1/3 ride.*

### Phase 1 — The SDF drawing core *(the robust centerpiece)*
Port iq's MIT 2D primitives + operators + transforms into `assets/js/humo/sdf/`
(WGSL source of truth, attribution headers), seeded by `wgsl-fns`. The Path-B
interpreter: a bounded instruction buffer the fragment shader walks, rendered to
the content texture so a composition condenses out of the smoke. Pure
composition/param math bun-tested. **(L — the load-bearing renderer.)**
*Exit:* a hardcoded shape composition (e.g. hexagon ∪ smooth-min circle) renders
from data and condenses in the fog.

### Phase 2 — The drawing spec + schema + validation
The JSON scene-tree schema, validator (clamped params, bounded counts), and
spec→instruction-buffer compiler. Golden-spec tests; malformed/oversized specs
fail closed. **(M)**

### Phase 3 — Diagrams (curated, our layout)
A `humo-graph` / `humo-uml` element set with home-grown Canvas2D layout
(node/edge placement, class boxes) → content texture, smoke-native. **(M–L)**
*Exit:* "draw the class diagram for Humo" appears in the fog, laid out by us.

### Phase 4 — Teaching + the expression skill
The **expression-grammar skill** (fits `skills.ex`): documents every block type,
its schema, and worked examples, loaded so the agent composes *well*, not just
legally. The difference between "can draw" and "draws the right thing." **(M)**

### Phase 5 — Robustness, safety, gallery
Schema hardening; structural caps tuned; **flash-rate limiting** on any animation
(photosensitivity — real-harm, non-negotiable); Sentinel event per expression; a
saved gallery (specs are tiny JSON). **(M)**

## Cross-cutting concerns
- **Licensing hygiene.** MIT/Apache/original only; iq attribution headers. Never
  ship hg_sdf or Shadertoy.
- **The agent composes, never codes.** Trust boundary = the validated block
  schema (Path B keeps it structural).
- **Accessibility.** Every expression is a flourish over the untouched DOM
  transcript; reduced-motion kills animation; nothing replaces the words.
- **Reuse.** Content modes ride the existing content-texture→smoke pipeline;
  style modes ride the uniform seam. Minimal new rendering.
- **Testing honesty.** Pure parse/compile/validate/layout logic is unit-tested;
  WGSL output is proven by eye + a spike, as in Humo.

## Open questions (need Luke)
1. **Draw vs accompany:** can the agent answer *purely* in a drawing/diagram, or
   does content always sit alongside text?
2. **How alive:** static first, or animation from the start (raises the
   flash-safety bar immediately)?
3. **2D only for v1?** (Recommended.) Reserve a 3D-raymarch stretch or not?
4. **Humo's model/prompt:** the appended expression guide grows the system prompt
   — cap its size, or a dedicated Humo model config (Humo Q5)?

## Non-goals
- External diagram/shader engines (Mermaid, thi.ng, hg_sdf, Shadertoy code).
- The agent writing raw WGSL/GLSL.
- 3D raymarched scenes in v1.
- A human-facing shader IDE / node editor.
- A separate open-source repo — this stays in-app (unlike `foreshadow`).

## Sequencing
Phase 0 (channel) gates everything — every mode needs it. Phase 1 (SDF core) is
the robust centerpiece and the load-bearing renderer decision; spike the
interpreter before the schema hardens (Phase 2). The expression skill (Phase 4)
is a hard dependency of the agent drawing *well*. Each phase ends with a dated
summary + inline **SHIPPED** marks, same convention as `HUMO_ROADMAP.md`.
