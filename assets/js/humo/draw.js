// Humo draw compiler (HUMO_EXPRESSION_ROADMAP.md, Phase 2). Turns an agent's
// shape list (from a `humo-draw` block) into the bounded Float32 instruction
// buffer the SDF pass walks. This is the trust boundary, and it is entirely
// data-driven: the vocabulary, slots, clamps, and defaults all come from
// sdf/schema.js, so this file never hand-codes a shape — it walks the schema.
// Unknown kinds are dropped, params are clamped to the schema's range, and the
// shape count is capped. The agent fills data, never code, and can't blow up
// the GPU or drift the layout out of sync with the shader.
import {clampR, clamp01} from "./params.js"
import {SHAPES, OPS, DEFAULT_OP, SMOOTH_K, COORD, CO, SIZE, UNIT} from "./sdf/schema.js"

export const MAX_SHAPES = 64
export const SHAPE_STRIDE = 12 // floats: a(4) + b(4) + c(4)

const num = (v, d) => (typeof v === "number" && isFinite(v) ? v : d)

// Clamp one field to its schema range. A missing/non-finite value falls back to
// the field's default; the default is always in-range so the result is too.
function clampField(clamp, v, def) {
  const n = num(v, def)
  switch (clamp) {
    case CO:
      return clampR(n, -COORD, COORD)
    case SIZE:
      return clampR(n, 0, COORD)
    case UNIT:
      return clamp01(n)
    default:
      return n
  }
}

// Encode a shape list → {buffer, count, report}. The buffer is always
// MAX_SHAPES wide so the storage binding is a fixed size; `count` tells the
// shader how many are live. `report` is fail-closed diagnostics for the caller
// (and Sentinel): what was dropped for an unknown kind and how many were shed
// because the spec ran past the cap — a silent truncation would read as
// "rendered everything" when it didn't.
export function encodeShapes(shapes) {
  const list = Array.isArray(shapes) ? shapes : []
  const buffer = new Float32Array(MAX_SHAPES * SHAPE_STRIDE)
  const report = {total: list.length, count: 0, dropped: 0, capped: 0}
  let n = 0

  for (const s of list) {
    const spec = SHAPES[s && s.kind]
    if (!spec) {
      report.dropped++ // unknown/malformed kind — fail closed, keep going
      continue
    }
    if (n >= MAX_SHAPES) {
      report.capped++ // valid but over the structural cap
      continue
    }

    const o = n * SHAPE_STRIDE
    buffer[o + 0] = spec.code
    buffer[o + 1] = OPS[s.op] ?? DEFAULT_OP
    buffer[o + 2] = clampR(num(s.k, SMOOTH_K.default), SMOOTH_K.min, SMOOTH_K.max)
    buffer[o + 3] = num(s.rot, 0)
    for (const field of spec.fields) {
      buffer[o + field.slot] = clampField(field.clamp, s[field.name], field.default)
    }
    n++
  }

  report.count = n
  return {buffer, count: n, report}
}
