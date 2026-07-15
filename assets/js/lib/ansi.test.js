// bun test — the transparent-background strip for TUIs over an image/shader.
// Run: bun test assets/js/lib/ (from the repo root)
import {describe, expect, test} from "bun:test"
import {stripTransparentBackgroundPaint, flushTransparentBackgroundPaint} from "./ansi.js"

const strip = (data, state = {pending: ""}) => stripTransparentBackgroundPaint(data, state)

describe("strips dark background paint so the wall shows through", () => {
  test("ANSI black background (40) — a now-empty SGR is dropped entirely", () => {
    expect(strip("\x1b[40mhi\x1b[0m")).toBe("hi\x1b[0m")
  })

  test("pure-black truecolor background (48;2;0;0;0)", () => {
    expect(strip("\x1b[48;2;0;0;0mx")).toBe("x")
  })

  test("Claude-style near-black neutral (48;2;26;26;26) — the reported bug", () => {
    expect(strip("\x1b[48;2;26;26;26mx")).toBe("x")
  })

  test("a dark neutral base like #1e1e2e (Catppuccin) is stripped", () => {
    expect(strip("\x1b[48;2;30;30;46mx")).toBe("x")
  })

  test("256-color pure black (48;5;16) and dark grey ramp (48;5;234)", () => {
    expect(strip("\x1b[48;5;16mx")).toBe("x")
    expect(strip("\x1b[48;5;234mx")).toBe("x")
  })

  test("keeps the non-background params in a mixed SGR", () => {
    // bold + red fg + black bg → keep bold + red fg, drop the bg.
    expect(strip("\x1b[1;31;40mx")).toBe("\x1b[1;31mx")
  })
})

describe("keeps deliberate, non-background colors", () => {
  test("a colored dark background (teal Solarized base, 48;2;0;43;54) is kept", () => {
    expect(strip("\x1b[48;2;0;43;54mx")).toBe("\x1b[48;2;0;43;54mx")
  })

  test("a light grey ramp entry (48;5;240 ≈ #585858) is kept", () => {
    expect(strip("\x1b[48;5;240mx")).toBe("\x1b[48;5;240mx")
  })

  test("a bright/colored background (48;2;200;30;30) is kept", () => {
    expect(strip("\x1b[48;2;200;30;30mx")).toBe("\x1b[48;2;200;30;30mx")
  })

  test("a foreground color is never touched (38;2;…)", () => {
    expect(strip("\x1b[38;2;0;0;0mx")).toBe("\x1b[38;2;0;0;0mx")
  })

  test("non-SGR CSI sequences pass through (cursor move)", () => {
    expect(strip("\x1b[2J\x1b[H\x1b[40mx")).toBe("\x1b[2J\x1b[Hx")
  })
})

describe("handles sequences split across chunks", () => {
  test("a CSI split mid-sequence is buffered, then completed", () => {
    const state = {pending: ""}
    // First chunk ends mid-escape; nothing emitted for the partial sequence.
    expect(strip("hi\x1b[48;2;26;26", state)).toBe("hi")
    expect(state.pending).toBe("\x1b[48;2;26;26")
    // Second chunk completes it → the dark bg is stripped across the boundary.
    expect(strip(";26mx", state)).toBe("x")
  })

  test("flush returns any dangling partial and clears it", () => {
    const state = {pending: ""}
    strip("hi\x1b[4", state)
    expect(flushTransparentBackgroundPaint(state)).toBe("\x1b[4")
    expect(state.pending).toBe("")
  })
})
