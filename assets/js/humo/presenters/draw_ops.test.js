import {describe, expect, test} from "bun:test"
import {sanitizeShapes, MAX_SHAPES} from "./draw_ops.js"

describe("sanitizeShapes (the drawing trust boundary)", () => {
  test("normalizes a circle and defaults the op to union", () => {
    const {shapes} = sanitizeShapes([{kind: "circle", x: 0.1, y: -0.2, r: 0.5}])
    expect(shapes[0]).toEqual({kind: "circle", op: "union", x: 0.1, y: -0.2, r: 0.5})
  })

  test("keeps known ops, falls back to union for unknown ones", () => {
    const {shapes} = sanitizeShapes([
      {kind: "box", op: "subtract"},
      {kind: "box", op: "nonsense"},
    ])
    expect(shapes[0].op).toBe("subtract")
    expect(shapes[1].op).toBe("union")
  })

  test("drops unknown kinds and malformed entries", () => {
    const {shapes, report} = sanitizeShapes([{kind: "dragon"}, null, {kind: "star", r: 0.3}])
    expect(shapes.map((s) => s.kind)).toEqual(["star"])
    expect(report.dropped).toBe(2)
  })

  test("clamps wild coordinates and sizes into range", () => {
    const {shapes} = sanitizeShapes([{kind: "circle", x: 99, y: -99, r: 99}])
    expect(shapes[0].x).toBe(2)
    expect(shapes[0].y).toBe(-2)
    expect(shapes[0].r).toBe(2)
  })

  test("star inner ratio clamps to [0,1]", () => {
    expect(sanitizeShapes([{kind: "star", inner: 5}]).shapes[0].inner).toBe(1)
    expect(sanitizeShapes([{kind: "star", inner: -1}]).shapes[0].inner).toBe(0)
  })

  test("caps at MAX_SHAPES and reports the overflow", () => {
    const many = Array.from({length: MAX_SHAPES + 12}, () => ({kind: "circle", r: 0.1}))
    const {shapes, report} = sanitizeShapes(many)
    expect(shapes.length).toBe(MAX_SHAPES)
    expect(report.capped).toBe(12)
    expect(report.dropped).toBe(0)
  })

  test("non-array input yields an empty drawing", () => {
    expect(sanitizeShapes(null).shapes).toEqual([])
    expect(sanitizeShapes("draw a cat").report.count).toBe(0)
  })
})
