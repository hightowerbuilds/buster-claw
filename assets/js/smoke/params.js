// Humo param math — every pure calculation between chat state and the GPU,
// factored out of the render loop so it is bun-testable (the GLSL/WGSL output
// itself is not unit-testable; this layer is, so it carries the tests).
//
// This is also the seed of the roadmap's "uniform-mapping layer": chat
// lifecycle → uniforms as data, not shader code. Phase 3 grows the vocabulary
// (uThinking, uAge, uWind…); the seam stays right here.

export const clamp01 = (x) => Math.max(0, Math.min(1, x))

export const clampR = (x, lo, hi) => Math.max(lo, Math.min(hi, x))

// Uniform buffer layout — must mirror `struct U` in smoke.wgsl.js:
// six vec4<f32> = 24 floats = 96 bytes.
//   [0] res.x  [1] res.y  [2..3] pad
//   [4] time   [5] intensity  [6] reveal  [7] freezeTime (lens hold timestamp)
//   [8] lens.x [9] lens.y (uv, y-up)  [10] lens radius  [11] lens strength
//   [12] mood energy  [13] mood temp (-1 cool .. +1 warm)  [14] mood density  [15] pad
//   [16] style pixelCell (1 = off)  [17] style paletteAmt (0 = off)  [18] motion (1 = full)  [19] pad
//   [20] post glow  [21] post grain  [22] post scanline  [23] post vignette
//   [24..26] colorA rgb  [27] pad   [28..30] colorB rgb  [31] pad   [32..34] colorC rgb  [35] pad
export const UNIFORM_FLOATS = 36

// Fallback palette (rgb 0..1) if no colors are supplied — the smoke defaults.
export const DEFAULT_COLORS = {
  a: [0.055, 0.055, 0.055],
  b: [1.0, 0.302, 0.11],
  c: [0.956, 0.945, 0.918],
}

// The hi-fi post stack, on by default — this is the modern/hi-fi look (glow,
// film grain, scanlines, edge vignette). Amounts are conservative starting
// points, tuned by eye in the app. `grain` is the only animated term, so
// reduced-motion drops it to 0 (the hook does this).
export const POST_DEFAULT = {
  glow: 0.5,
  grain: 0.05,
  scanline: 0.12,
  vignette: 0.35,
}

// The neutral expression: reproduces the base look exactly (energy/density 0.5,
// temp 0, no pixelation). Every field eases toward this when nothing is set.
export const NEUTRAL_EXPRESSION = {
  energy: 0.5,
  temp: 0,
  density: 0.5,
  pixelCell: 1,
  paletteAmt: 0,
}

export function packUniforms(
  {width, height, timeSec, intensity, reveal, freezeTime = 0, lens, expression, post, motion = 1, colors},
  out
) {
  const e = expression || NEUTRAL_EXPRESSION
  const pp = post || POST_DEFAULT
  const c = colors || DEFAULT_COLORS
  const u = out || new Float32Array(UNIFORM_FLOATS)
  u[0] = width
  u[1] = height
  u[2] = 0
  u[3] = 0
  u[4] = timeSec
  u[5] = intensity
  u[6] = clamp01(reveal)
  u[7] = freezeTime
  u[8] = lens ? lens.x : 0
  u[9] = lens ? lens.y : 0
  u[10] = lens ? lens.radius : 0
  u[11] = lens ? clamp01(lens.strength) : 0
  u[12] = clamp01(e.energy)
  u[13] = clampR(e.temp, -1, 1)
  u[14] = clamp01(e.density)
  u[15] = 0
  u[16] = Math.max(1, e.pixelCell)
  u[17] = clamp01(e.paletteAmt)
  u[18] = clamp01(motion)
  u[19] = 0
  u[20] = clamp01(pp.glow)
  u[21] = clamp01(pp.grain)
  u[22] = clamp01(pp.scanline)
  u[23] = clamp01(pp.vignette)
  u[24] = c.a[0]
  u[25] = c.a[1]
  u[26] = c.a[2]
  u[27] = 0
  u[28] = c.b[0]
  u[29] = c.b[1]
  u[30] = c.b[2]
  u[31] = 0
  u[32] = c.c[0]
  u[33] = c.c[1]
  u[34] = c.c[2]
  u[35] = 0
  return u
}

// Normalize an agent-emitted `humo-style` spec into a clamped expression the
// renderer can ease toward. Temperature accepts words or a number; a `mode`
// selects a render style (gameboy → chunky pixels + DMG palette). Unknown keys
// are ignored — the trust boundary is this normalizer, not the raw JSON.
export function styleFromSpec(spec) {
  const s = spec || {}
  const out = {...NEUTRAL_EXPRESSION}
  if (typeof s.energy === "number") out.energy = clamp01(s.energy)
  if (typeof s.density === "number") out.density = clamp01(s.density)
  if (s.temp != null) out.temp = tempToNumber(s.temp)
  if (s.mode === "gameboy" || s.mode === "pixel") {
    out.pixelCell = s.mode === "gameboy" ? 6 : 4
    out.paletteAmt = s.mode === "gameboy" ? 1 : 0
  }
  return out
}

function tempToNumber(t) {
  if (typeof t === "number") return clampR(t, -1, 1)
  const word = {cold: -1, cool: -0.6, neutral: 0, warm: 0.6, hot: 1}[String(t).toLowerCase()]
  return word == null ? 0 : word
}

// Ease `cur` toward `target` field by field (called per frame). Snaps when
// close so an idle expression costs nothing and never jitters.
export function easeExpression(cur, target, k = 0.08) {
  const out = {}
  for (const key of Object.keys(NEUTRAL_EXPRESSION)) {
    const c = cur[key], t = target[key]
    const next = c + (t - c) * k
    out[key] = Math.abs(t - next) < 0.001 ? t : next
  }
  return out
}

// Reveal sweep for a streaming message: 0 → 1 across the expected stream
// duration plus a settle tail, slightly overdriven (×1.15) so the text is
// fully condensed shortly after the last token rather than exactly at it.
export function revealProgress({elapsedMs, totalWords, msPerWord = 85, tailMs = 900}) {
  const duration = totalWords * msPerWord + tailMs
  if (duration <= 0) return 1
  return clamp01((elapsedMs / duration) * 1.15)
}

// Per-page reveal clock for the smoke readout. A page condenses in over
// condenseMs as it fills (then holds at 1), and dissolves back to 0 over
// dissolveMs when full — making room for the next page of words.
export function pageReveal({phase, sincePhaseMs, condenseMs = 800, dissolveMs = 700}) {
  if (phase === "dissolving") {
    if (dissolveMs <= 0) return 0
    return 1 - clamp01(sincePhaseMs / dissolveMs)
  }
  if (condenseMs <= 0) return 1
  return clamp01(sincePhaseMs / condenseMs)
}

// The mapping layer, v0: conversation phase → uniform values. Deliberately
// tiny — it maps onto the two knobs the shader has today (intensity, reveal).
// Phase 3 extends both sides in lockstep.
//
// state: {phase: "idle"|"thinking"|"streaming"|"settled", streamProgress?: 0..1}
export function mapChatState(state) {
  switch (state.phase) {
    case "thinking":
      // No words yet — the churn IS the message.
      return {intensity: 1.35, reveal: 0}
    case "streaming":
      return {intensity: 1.0, reveal: clamp01(state.streamProgress ?? 0)}
    case "settled":
      return {intensity: 0.9, reveal: 1}
    default:
      // idle — ambient drift, nothing condensing.
      return {intensity: 0.85, reveal: 0}
  }
}
