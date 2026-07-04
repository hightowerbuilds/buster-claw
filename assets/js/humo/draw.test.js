import {describe, expect, test} from "bun:test"
import {encodeShapes, MAX_SHAPES, SHAPE_STRIDE} from "./draw.js"
import {SMOOTH_K} from "./sdf/schema.js"

describe("encodeShapes (the drawing trust boundary)", () => {
  test("encodes a circle into the a/b/c layout", () => {
    const {buffer, count} = encodeShapes([{kind: "circle", x: 0.1, y: -0.2, r: 0.5, op: "union"}])
    expect(count).toBe(1)
    expect(buffer.length).toBe(MAX_SHAPES * SHAPE_STRIDE)
    expect(buffer[0]).toBe(0) // kind = circle
    expect(buffer[1]).toBe(0) // op = union
    expect(buffer[4]).toBeCloseTo(0.1) // center.x
    expect(buffer[5]).toBeCloseTo(-0.2) // center.y
    expect(buffer[8]).toBeCloseTo(0.5) // radius (c.x)
  })

  test("maps ops and kinds by name", () => {
    const {buffer} = encodeShapes([
      {kind: "box", x: 0, y: 0, w: 0.3, h: 0.2, op: "subtract"},
      {kind: "star", x: 0, y: 0, r: 0.4, inner: 0.5, op: "smooth"},
    ])
    expect(buffer[0]).toBe(1) // box
    expect(buffer[1]).toBe(1) // subtract
    expect(buffer[SHAPE_STRIDE + 0]).toBe(6) // star
    expect(buffer[SHAPE_STRIDE + 1]).toBe(3) // smooth
    expect(buffer[SHAPE_STRIDE + 9]).toBeCloseTo(0.5) // inner ratio
  })

  test("segment packs both endpoints into b, thickness into c.x", () => {
    const {buffer} = encodeShapes([{kind: "segment", x1: -0.5, y1: 0, x2: 0.5, y2: 0.1, th: 0.02}])
    expect(buffer[0]).toBe(3)
    expect(buffer[4]).toBeCloseTo(-0.5)
    expect(buffer[6]).toBeCloseTo(0.5)
    expect(buffer[7]).toBeCloseTo(0.1)
    expect(buffer[8]).toBeCloseTo(0.02)
  })

  test("unknown kinds are dropped, not encoded", () => {
    const {count} = encodeShapes([{kind: "dragon"}, {kind: "circle", r: 0.3}])
    expect(count).toBe(1)
  })

  test("caps at MAX_SHAPES", () => {
    const many = Array.from({length: MAX_SHAPES + 20}, () => ({kind: "circle", r: 0.1}))
    expect(encodeShapes(many).count).toBe(MAX_SHAPES)
  })

  test("clamps wild coordinates so geometry can't fly to infinity", () => {
    const {buffer} = encodeShapes([{kind: "circle", x: 9999, y: -9999, r: 9999}])
    expect(buffer[4]).toBe(4)
    expect(buffer[5]).toBe(-4)
    expect(buffer[8]).toBe(4)
  })

  test("non-array input yields an empty scene", () => {
    expect(encodeShapes(null).count).toBe(0)
    expect(encodeShapes("draw a cat").count).toBe(0)
  })
})

describe("encodeShapes golden specs (spec → exact instruction buffer)", () => {
  // The roadmap's canonical Phase 1 composition, pinned float-for-float so a
  // change to the schema slots or the encoder can't silently reshape the buffer
  // the shader reads.
  test("hexagon ∪ smooth-min circle", () => {
    const {buffer, count} = encodeShapes([
      {kind: "hexagon", x: 0, y: 0, r: 0.5, op: "union"},
      {kind: "circle", x: 0.3, y: 0, r: 0.35, op: "smooth", k: 0.2},
    ])
    expect(count).toBe(2)

    // Shape 0 — hexagon: a=(code5, union0, defaultK, rot0), c.x=r. Exact slots
    // asserted directly; 0.08 isn't Float32-exact so it rides toBeCloseTo.
    const s0 = Array.from(buffer.slice(0, SHAPE_STRIDE))
    expect(s0[0]).toBe(5) // code = hexagon
    expect(s0[1]).toBe(0) // op = union
    expect(s0[2]).toBeCloseTo(0.08) // default smooth-k
    expect(s0[3]).toBe(0) // rotation
    expect(s0[4]).toBe(0) // center.x
    expect(s0[5]).toBe(0) // center.y
    expect(s0[8]).toBe(0.5) // radius (c.x), Float32-exact
    // Shape 1 — circle: a=(code0, smooth3, k0.2, rot0), b.xy=center, c.x=r
    const s1 = Array.from(buffer.slice(SHAPE_STRIDE, 2 * SHAPE_STRIDE))
    expect(s1[0]).toBe(0) // code = circle
    expect(s1[1]).toBe(3) // op = smooth
    expect(s1[2]).toBeCloseTo(0.2) // smooth-union radius k
    expect(s1[4]).toBeCloseTo(0.3) // center.x
    expect(s1[8]).toBeCloseTo(0.35) // radius
  })

  test("rotation lands in a.w, smooth-k clamps to its range", () => {
    const {buffer} = encodeShapes([{kind: "box", x: 0, y: 0, w: 0.2, h: 0.2, rot: 0.7, k: 99}])
    expect(buffer[3]).toBeCloseTo(0.7) // rotation
    expect(buffer[2]).toBe(SMOOTH_K.max) // k clamped to 1
  })
})

describe("encodeShapes report (fail-closed diagnostics)", () => {
  test("counts total, encoded, dropped, and capped", () => {
    const {report} = encodeShapes([
      {kind: "circle", r: 0.3},
      {kind: "dragon"}, // unknown → dropped
      {kind: "box"},
      null, // malformed → dropped
    ])
    expect(report.total).toBe(4)
    expect(report.count).toBe(2)
    expect(report.dropped).toBe(2)
    expect(report.capped).toBe(0)
  })

  test("shapes past MAX_SHAPES are reported as capped, not dropped", () => {
    const over = 20
    const {count, report} = encodeShapes(
      Array.from({length: MAX_SHAPES + over}, () => ({kind: "circle", r: 0.1}))
    )
    expect(count).toBe(MAX_SHAPES)
    expect(report.capped).toBe(over)
    expect(report.dropped).toBe(0)
  })
})
