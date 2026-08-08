---
name: shader-designer
description: Playbook for designing a new homepage WebGPU (WGSL) shader pattern — the prelude contract, palette system, and fs_main structure, with the shipped shaders as worked examples.
tier: safe
enabled: true
handler_kind: reference
---

# shader-designer

A **reference** skill: read this, then WRITE a WGSL fragment shader for a new
homepage background pattern. You author ONE file in this workspace; the app
compiles it live in the browser — no rebuild — and it renders only when the
user selects it in Settings → Appearance. You propose patterns; the user
chooses them.

## What a shader pattern is

The homepage background is a full-screen WebGPU fragment shader. A custom
pattern is one file `shaders/<name>.wgsl` in this workspace containing ONLY
the fragment code — your own helper functions plus the entry point
`fs_main`. The app prepends a shared prelude (the uniform contract and a
helper library) and compiles the result live, so the moment the file exists
it appears as a selectable design in Settings → Appearance, with a live
preview.

Hard constraints — a file that breaks one is ignored or fails to compile:
- Name: lowercase `[a-z0-9-]` (e.g. `ember-drift.wgsl`). The names
  `smoke`, `waves`, `mandel`, `weather` belong to built-ins and
  are shadowed — pick something else.
- At most 64 KB, and it must define `fn fs_main`.
- Do NOT redeclare anything the prelude already provides (see below) — a
  duplicate declaration is a WGSL compile error.

The four built-ins are worked examples of the same contract: `smoke`
(domain-warped fbm), `waves`, `mandel` (fractal zoom), and `weather`
(a ~2-minute sky clock — the most complete).
If you have the repo checkout, read them in `assets/js/smoke/*.wgsl.js`.

## The prelude contract (what you get for free)

Uniforms (struct `U` at binding 0), all `vec4<f32>`:
- `u.res`    — `.xy` = pixel resolution.
- `u.params` — `.x` = time in seconds, `.y` = intensity / interaction amount.
- `u.style`  — `.z` = a speed multiplier (fold it into your time).
- `u.post`   — `(glow, grain, scanline, vignette)` for `bg_post`.
- `u.colA` / `u.colB` / `u.colC` — the 3-colour palette (`.xyz`): base /
  mid-accent / highlight. ALWAYS colour through these so custom palettes work.

Vertex output you receive: `VOut { @builtin(position) pos, @location(0) uv }`,
where `uv` is `0..1` with a bottom-left origin.

Helpers from the prelude (use them, don't re-roll):
- `hash(vec2) -> f32`, `fbm(vec2) -> f32` — value noise / fractal Brownian motion.
- `grad3(t, a, b, c) -> vec3` — map a scalar through the 3-colour palette.
- `touch() -> f32` — an interaction signal.
- `bg_post(col, uv, res, time, post) -> vec3` — the shared tonemap + vignette +
  scanline + grain pass. Call it LAST.

## The shape of an fs_main

    @fragment
    fn fs_main(in: VOut) -> @location(0) vec4<f32> {
      let res = u.res.xy;
      let time = u.params.x * u.style.z;   // fold in the speed multiplier
      let uv = in.uv;
      // ...build a scalar field or colour from uv / time / fbm...
      var col = grad3(field, u.colA.xyz, u.colB.xyz, u.colC.xyz);
      col = col + vec3<f32>(touch());      // optional interaction lift
      col = bg_post(col, uv, res, time, u.post);
      return vec4<f32>(col, 1.0);
    }

Rules of thumb:
- Colour ONLY through `u.colA/B/C` — never hardcode colours. A custom
  pattern has no palette entry of its own: with custom colours off it gets
  the Industrial default (`#0e0e0e` base / `#ff4d1c` accent / `#f4f1ea`
  highlight), so design to read well on that trio; the user can re-tint it
  with custom colours.
- Aspect-correct when you need round shapes: `uv * vec2(res.x/res.y, 1.0)`.
- Keep it a *background*: subtle, looping, no harsh flashing.
- Custom patterns render at full canvas density (built-ins get hand-tuned
  low-res tiers; yours doesn't), so keep per-pixel cost modest — prefer
  fbm-style fields over deep iteration loops or raymarching.

## Palette roles

Give each palette colour a consistent role and note it in a header comment —
e.g. `weather` uses `colA` = sky, `colB` = cloud/mid, `colC` = highlight — so a
custom palette re-tints the pattern coherently.

## Shipping it (no build step)

1. Write `shaders/<name>.wgsl` in this workspace — fragment code only: no
   prelude copy, no JS wrapper, no `export`.
2. That's it. The pattern is now listed in Settings → Appearance → Homepage
   background; its WGSL is served from `/shaders/<name>` and compiled in the
   webview when previewed or selected.
3. It renders only when the **user** selects it. Tell the user the pattern's
   name and what it looks like so they can try it.

Verify: selecting it in Settings shows a live preview immediately. A WGSL
compile error leaves the canvas blank and puts
`unavailable:WGSL: <line>:<message>` in the preview container's
`data-preview` attribute (`data-smoke` on the homepage) and the console. To
iterate, edit the file and re-select the pattern — the WGSL is re-fetched
fresh every time (served no-store).
"""
