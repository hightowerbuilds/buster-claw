// Humo param math — every pure calculation between chat state and the GPU,
// factored out of the render loop so it is bun-testable (the GLSL/WGSL output
// itself is not unit-testable; this layer is, so it carries the tests).
//
// This is also the seed of the roadmap's "uniform-mapping layer": chat
// lifecycle → uniforms as data, not shader code. Phase 3 grows the vocabulary
// (uThinking, uAge, uWind…); the seam stays right here.

export const clamp01 = (x) => Math.max(0, Math.min(1, x))

// Uniform buffer layout — must mirror `struct U` in smoke_wgsl.js:
// three vec4<f32> = 12 floats = 48 bytes.
//   [0] res.x  [1] res.y  [2..3] pad
//   [4] time   [5] intensity  [6] reveal  [7] freezeTime (lens hold timestamp)
//   [8] lens.x [9] lens.y (uv, y-up)  [10] lens radius  [11] lens strength
export const UNIFORM_FLOATS = 12

export function packUniforms(
  {width, height, timeSec, intensity, reveal, freezeTime = 0, lens},
  out
) {
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
  return u
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
