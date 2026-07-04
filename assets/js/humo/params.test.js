import {describe, expect, test} from "bun:test"
import {
  clamp01,
  packUniforms,
  revealProgress,
  pageReveal,
  mapChatState,
  UNIFORM_FLOATS,
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
