import {expect, test, describe} from "bun:test"
import {msAtRatio, selection, isMeaningful, overlay, MIN_SELECTION_MS} from "./trim.js"

describe("msAtRatio", () => {
  test("maps a ratio across the clip", () => {
    expect(msAtRatio(0, 1000)).toBe(0)
    expect(msAtRatio(0.5, 1000)).toBe(500)
    expect(msAtRatio(1, 1000)).toBe(1000)
  })

  test("clamps past either edge — this is how you select to the very end", () => {
    expect(msAtRatio(-0.4, 1000)).toBe(0)
    expect(msAtRatio(1.9, 1000)).toBe(1000)
  })

  test("an unknown duration yields 0 rather than NaN", () => {
    // A file whose length we could not read must not produce a selection of
    // NaN..NaN and hand that to a splice.
    expect(msAtRatio(0.5, 0)).toBe(0)
    expect(msAtRatio(0.5, NaN)).toBe(0)
    expect(msAtRatio(0.5, -100)).toBe(0)
  })
})

describe("selection", () => {
  test("dragging rightward and leftward give the same selection", () => {
    expect(selection(200, 700)).toEqual({from: 200, to: 700})
    expect(selection(700, 200)).toEqual({from: 200, to: 700})
  })

  test("a stationary pointer is an empty selection, not an inverted one", () => {
    expect(selection(300, 300)).toEqual({from: 300, to: 300})
  })
})

describe("isMeaningful", () => {
  test("separates a drag from a click", () => {
    expect(isMeaningful({from: 0, to: MIN_SELECTION_MS})).toBe(true)
    expect(isMeaningful({from: 0, to: MIN_SELECTION_MS - 1})).toBe(false)
    expect(isMeaningful({from: 500, to: 500})).toBe(false)
  })
})

describe("overlay", () => {
  test("shades the unselected ends and marks both edges", () => {
    expect(overlay({from: 250, to: 750}, 1000)).toEqual({
      left: 25,
      right: 25,
      edgeA: 25,
      edgeB: 75,
    })
  })

  test("a full selection shades nothing", () => {
    expect(overlay({from: 0, to: 1000}, 1000)).toEqual({
      left: 0,
      right: 0,
      edgeA: 0,
      edgeB: 100,
    })
  })

  test("edges agree with the shades they abut — no seam", () => {
    const {left, edgeA, right, edgeB} = overlay({from: 123, to: 456}, 789)

    // `edgeA` and `left` are the same computation, so they match exactly.
    expect(edgeA).toBe(left)
    // `edgeB` and `100 - right` are two different routes to the same edge, so
    // they agree to floating-point noise rather than bit-for-bit. The guarantee
    // being made is "no visible seam", not bit-exactness — at ~1e-13 of a
    // percent, the two land on the same device pixel of any real display.
    expect(edgeB).toBeCloseTo(100 - right, 10)
  })

  test("an unknown duration collapses to nothing drawn", () => {
    expect(overlay({from: 0, to: 10}, 0)).toEqual({left: 0, right: 0, edgeA: 0, edgeB: 0})
  })
})
