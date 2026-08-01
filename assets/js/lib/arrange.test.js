import {expect, test, describe} from "bun:test"
import {msAtRatio, dropStartMs, laneIndexAt} from "./arrange.js"

describe("msAtRatio", () => {
  test("maps a ratio along the ruler", () => {
    expect(msAtRatio(0, 10_000)).toBe(0)
    expect(msAtRatio(0.5, 10_000)).toBe(5_000)
    expect(msAtRatio(1, 10_000)).toBe(10_000)
  })

  test("clamps past either edge instead of leaving the ruler", () => {
    expect(msAtRatio(-1, 10_000)).toBe(0)
    expect(msAtRatio(2, 10_000)).toBe(10_000)
  })

  test("an unknown view yields 0 rather than NaN", () => {
    // A NaN start_ms would be persisted into the track file and break layout
    // for every later render.
    expect(msAtRatio(0.5, 0)).toBe(0)
    expect(msAtRatio(0.5, NaN)).toBe(0)
    expect(msAtRatio(0.5, -5)).toBe(0)
  })
})

describe("dropStartMs", () => {
  test("preserves where the clip was grabbed", () => {
    // Grabbed 200 ms in, dropped with the pointer at 5000 → the clip starts at
    // 4800. Otherwise every drag snaps the left edge to the cursor.
    expect(dropStartMs(5_000, 200)).toBe(4_800)
  })

  test("a clip grabbed by its left edge lands under the pointer", () => {
    expect(dropStartMs(5_000, 0)).toBe(5_000)
  })

  test("cannot land before the start of the ruler", () => {
    expect(dropStartMs(100, 900)).toBe(0)
  })
})

describe("laneIndexAt", () => {
  const rects = [
    {top: 0, bottom: 50},
    {top: 60, bottom: 110},
    {top: 120, bottom: 170},
  ]

  test("finds the row under the pointer", () => {
    expect(laneIndexAt(25, rects)).toBe(0)
    expect(laneIndexAt(80, rects)).toBe(1)
    expect(laneIndexAt(150, rects)).toBe(2)
  })

  test("a pointer in the gap between rows still chooses one", () => {
    // Landing on a border or a 10px gutter must not cancel the drag.
    expect(laneIndexAt(55, rects)).toBe(2)
  })

  test("past either end, clamps to the nearest lane", () => {
    expect(laneIndexAt(-999, rects)).toBe(0)
    expect(laneIndexAt(9_999, rects)).toBe(2)
  })

  test("no lanes is a non-answer, not a crash", () => {
    expect(laneIndexAt(10, [])).toBe(-1)
    expect(laneIndexAt(10, null)).toBe(-1)
  })
})
