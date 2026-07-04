import {describe, expect, test} from "bun:test"
import {
  clamp01,
  packUniforms,
  revealProgress,
  pageReveal,
  mapChatState,
  styleFromSpec,
  easeExpression,
  NEUTRAL_EXPRESSION,
  UNIFORM_FLOATS,
  POST_DEFAULT,
} from "./params.js"

describe("clamp01", () => {
  test("clamps below, above, and passes through", () => {
    expect(clamp01(-1)).toBe(0)
    expect(clamp01(2)).toBe(1)
    expect(clamp01(0.5)).toBe(0.5)
  })
})

describe("packUniforms", () => {
  test("layout mirrors struct U: res, time/intensity/reveal/freeze, lens vec4", () => {
    const u = packUniforms({
      width: 800,
      height: 600,
      timeSec: 1.5,
      intensity: 1.2,
      reveal: 0.4,
      freezeTime: 9.25,
      lens: {x: 0.3, y: 0.7, radius: 0.16, strength: 0.5},
    })
    expect(u.length).toBe(UNIFORM_FLOATS)
    expect(u[0]).toBe(800)
    expect(u[1]).toBe(600)
    expect(u[4]).toBe(1.5)
    expect(u[5]).toBeCloseTo(1.2)
    expect(u[6]).toBeCloseTo(0.4)
    expect(u[7]).toBeCloseTo(9.25)
    expect(u[8]).toBeCloseTo(0.3)
    expect(u[9]).toBeCloseTo(0.7)
    expect(u[10]).toBeCloseTo(0.16)
    expect(u[11]).toBeCloseTo(0.5)
  })

  test("lens is optional and off by default", () => {
    const u = packUniforms({width: 1, height: 1, timeSec: 0, intensity: 1, reveal: 0})
    expect(u[7]).toBe(0)
    expect(u[11]).toBe(0)
  })

  test("post stack defaults to the hi-fi look and honours an override", () => {
    const base = packUniforms({width: 1, height: 1, timeSec: 0, intensity: 1, reveal: 0})
    expect(base[20]).toBeCloseTo(POST_DEFAULT.glow)
    expect(base[21]).toBeCloseTo(POST_DEFAULT.grain)
    expect(base[22]).toBeCloseTo(POST_DEFAULT.scanline)
    expect(base[23]).toBeCloseTo(POST_DEFAULT.vignette)
    expect(base[18]).toBe(1) // motion defaults to full

    // Reduced-motion drops grain to 0; other terms clamp to [0,1].
    const u = packUniforms({
      width: 1,
      height: 1,
      timeSec: 0,
      intensity: 1,
      reveal: 0,
      post: {glow: 2, grain: 0, scanline: 0.3, vignette: 0.4},
    })
    expect(u[20]).toBe(1) // clamped
    expect(u[21]).toBe(0) // grain off

    // Reduced-motion passes a low motion scale.
    expect(packUniforms({width: 1, height: 1, timeSec: 0, intensity: 1, reveal: 0, motion: 0.25})[18]).toBe(0.25)
  })

  test("packs the 3-color palette into slots 24..34 (rgb, padded)", () => {
    const u = packUniforms({
      width: 1,
      height: 1,
      timeSec: 0,
      intensity: 1,
      reveal: 0,
      colors: {a: [1, 0, 0], b: [0, 0.5, 0], c: [0, 0, 1]},
    })
    expect([u[24], u[25], u[26], u[27]]).toEqual([1, 0, 0, 0])
    expect([u[28], u[29], u[30], u[31]]).toEqual([0, 0.5, 0, 0])
    expect([u[32], u[33], u[34], u[35]]).toEqual([0, 0, 1, 0])
  })

  test("clamps reveal and lens strength, reuses a provided buffer", () => {
    const buf = new Float32Array(UNIFORM_FLOATS)
    const out = packUniforms(
      {
        width: 1,
        height: 1,
        timeSec: 0,
        intensity: 1,
        reveal: 7,
        lens: {x: 0, y: 0, radius: 0.2, strength: 3},
      },
      buf
    )
    expect(out).toBe(buf)
    expect(out[6]).toBe(1)
    expect(out[11]).toBe(1)
  })
})

describe("revealProgress", () => {
  test("starts at 0, overdrives past the nominal duration, caps at 1", () => {
    const args = {totalWords: 10, msPerWord: 100, tailMs: 0}
    expect(revealProgress({...args, elapsedMs: 0})).toBe(0)
    // ×1.15 overdrive: fully condensed before elapsed == duration
    expect(revealProgress({...args, elapsedMs: 1000})).toBe(1)
    expect(revealProgress({...args, elapsedMs: 500})).toBeCloseTo(0.575)
  })

  test("zero-length message is immediately revealed", () => {
    expect(revealProgress({elapsedMs: 0, totalWords: 0, msPerWord: 85, tailMs: 0})).toBe(1)
  })
})

describe("styleFromSpec (the expression normalizer / trust boundary)", () => {
  test("neutral for an empty spec", () => {
    expect(styleFromSpec({})).toEqual(NEUTRAL_EXPRESSION)
    expect(styleFromSpec(undefined)).toEqual(NEUTRAL_EXPRESSION)
  })

  test("maps mood fields and clamps energy/density", () => {
    const s = styleFromSpec({energy: 2, density: -1, temp: 0.3})
    expect(s.energy).toBe(1)
    expect(s.density).toBe(0)
    expect(s.temp).toBeCloseTo(0.3)
  })

  test("temperature words resolve to numbers", () => {
    expect(styleFromSpec({temp: "cool"}).temp).toBeCloseTo(-0.6)
    expect(styleFromSpec({temp: "warm"}).temp).toBeCloseTo(0.6)
    expect(styleFromSpec({temp: "neutral"}).temp).toBe(0)
    expect(styleFromSpec({temp: "nonsense"}).temp).toBe(0)
  })

  test("gameboy mode sets pixel cell + palette; pixel mode is chunky only", () => {
    const gb = styleFromSpec({mode: "gameboy"})
    expect(gb.pixelCell).toBe(6)
    expect(gb.paletteAmt).toBe(1)
    const px = styleFromSpec({mode: "pixel"})
    expect(px.pixelCell).toBe(4)
    expect(px.paletteAmt).toBe(0)
  })

  test("unknown keys are ignored", () => {
    expect(styleFromSpec({haxx: "rm -rf", energy: 0.5})).toEqual({
      ...NEUTRAL_EXPRESSION,
      energy: 0.5,
    })
  })
})

describe("easeExpression", () => {
  test("moves toward the target and snaps when close", () => {
    const mid = easeExpression(NEUTRAL_EXPRESSION, {...NEUTRAL_EXPRESSION, energy: 1}, 0.5)
    expect(mid.energy).toBeCloseTo(0.75)
    const snapped = easeExpression({...NEUTRAL_EXPRESSION, energy: 0.9995}, {
      ...NEUTRAL_EXPRESSION,
      energy: 1,
    })
    expect(snapped.energy).toBe(1)
  })
})

describe("packUniforms expression fields", () => {
  test("neutral expression writes base values; gameboy writes pixel + palette", () => {
    const base = packUniforms({width: 1, height: 1, timeSec: 0, intensity: 1, reveal: 0})
    expect(base.length).toBe(UNIFORM_FLOATS)
    expect(base[12]).toBe(0.5) // energy
    expect(base[16]).toBe(1) // pixelCell (off)
    expect(base[17]).toBe(0) // paletteAmt (off)

    const gb = packUniforms({
      width: 1,
      height: 1,
      timeSec: 0,
      intensity: 1,
      reveal: 0,
      expression: styleFromSpec({mode: "gameboy", temp: "warm"}),
    })
    expect(gb[13]).toBeCloseTo(0.6) // temp warm
    expect(gb[16]).toBe(6) // pixelCell
    expect(gb[17]).toBe(1) // paletteAmt
  })
})

describe("pageReveal (the readout's page clock)", () => {
  test("filling condenses in over condenseMs then holds at 1", () => {
    expect(pageReveal({phase: "filling", sincePhaseMs: 0, condenseMs: 800})).toBe(0)
    expect(pageReveal({phase: "filling", sincePhaseMs: 400, condenseMs: 800})).toBeCloseTo(0.5)
    expect(pageReveal({phase: "filling", sincePhaseMs: 5000, condenseMs: 800})).toBe(1)
  })

  test("dissolving sweeps 1 → 0 over dissolveMs", () => {
    expect(pageReveal({phase: "dissolving", sincePhaseMs: 0, dissolveMs: 700})).toBe(1)
    expect(pageReveal({phase: "dissolving", sincePhaseMs: 350, dissolveMs: 700})).toBeCloseTo(0.5)
    expect(pageReveal({phase: "dissolving", sincePhaseMs: 700, dissolveMs: 700})).toBe(0)
    expect(pageReveal({phase: "dissolving", sincePhaseMs: 9999, dissolveMs: 700})).toBe(0)
  })

  test("degenerate durations don't divide by zero", () => {
    expect(pageReveal({phase: "filling", sincePhaseMs: 0, condenseMs: 0})).toBe(1)
    expect(pageReveal({phase: "dissolving", sincePhaseMs: 0, dissolveMs: 0})).toBe(0)
  })
})

describe("mapChatState (the uniform-mapping layer, v0)", () => {
  test("thinking churns with no reveal", () => {
    expect(mapChatState({phase: "thinking"})).toEqual({intensity: 1.35, reveal: 0})
  })
  test("streaming tracks progress", () => {
    expect(mapChatState({phase: "streaming", streamProgress: 0.3}).reveal).toBeCloseTo(0.3)
  })
  test("settled is fully condensed, idle fully dissolved", () => {
    expect(mapChatState({phase: "settled"}).reveal).toBe(1)
    expect(mapChatState({phase: "idle"}).reveal).toBe(0)
  })
  test("streaming with missing progress defaults to 0, out-of-range clamps", () => {
    expect(mapChatState({phase: "streaming"}).reveal).toBe(0)
    expect(mapChatState({phase: "streaming", streamProgress: 9}).reveal).toBe(1)
  })
})
