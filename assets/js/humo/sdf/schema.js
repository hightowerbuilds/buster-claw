// The Humo drawing schema (HUMO_EXPRESSION_ROADMAP.md, Phase 2). The single
// source of truth for what the agent may draw: every shape kind, its GPU code,
// and where each of its params lands in the 12-float shape record plus how that
// param is clamped. `draw.js` is a generic walk over this table and the SDF
// interpreter (sdf/pass.wgsl.js) reads the same slots — so the JSON the agent
// sends, the bytes the GPU reads, and the validation caps all derive from one
// place and can't drift apart by hand. Adding a shape is one entry here + one
// branch in the interpreter, nothing else.

// A shape record is three vec4 = 12 floats:
//   a = (kind, op, smoothK, rotation)   slots 0..3   — set by the encoder itself
//   b = (x, y, ptB.x, ptB.y)            slots 4..7
//   c = (size.x, size.y, size.z, ptC.y) slots 8..11
// Fields below place a named JSON param into one of slots 4..11.

// Clamp kinds. Coordinates get a generous cap so a stray value can't fling
// geometry to infinity without cramping composition; sizes are non-negative;
// unit params (e.g. star inner ratio) ride [0,1].
export const CO = "co" // draw-space coordinate, clamped to [-COORD, COORD]
export const SIZE = "size" // non-negative extent, clamped to [0, COORD]
export const UNIT = "unit" // clamped to [0,1]

export const COORD = 4 // draw space is ~[-1,1]; 4 leaves generous headroom

export const OPS = {union: 0, subtract: 1, intersect: 2, smooth: 3}
export const DEFAULT_OP = OPS.union

// Smooth-union blend radius (a.z): shared by all kinds, only used by the smooth
// op. Kept tight so a blend can't smear the whole scene.
export const SMOOTH_K = {default: 0.08, min: 0.001, max: 1}

const f = (name, slot, clamp, def = 0) => ({name, slot, clamp, default: def})

// kind → {code, fields}. `code` mirrors the `if (kind == N)` ladder in
// sdf/pass.wgsl.js. Field slots mirror the param reads in that same shader.
export const SHAPES = {
  // center + radius
  circle: {code: 0, fields: [f("x", 4, CO), f("y", 5, CO), f("r", 8, SIZE, 0.4)]},
  // center + half-size
  box: {code: 1, fields: [f("x", 4, CO), f("y", 5, CO), f("w", 8, SIZE, 0.3), f("h", 9, SIZE, 0.3)]},
  // center + half-size + corner radius
  roundbox: {
    code: 2,
    fields: [f("x", 4, CO), f("y", 5, CO), f("w", 8, SIZE, 0.3), f("h", 9, SIZE, 0.3), f("radius", 10, SIZE, 0.05)],
  },
  // endpoints A (b.xy) and B (b.zw) + thickness (c.x); not translated/rotated
  segment: {
    code: 3,
    fields: [f("x1", 4, CO), f("y1", 5, CO), f("x2", 6, CO), f("y2", 7, CO), f("th", 8, SIZE, 0.02)],
  },
  // three points p0 (b.xy), p1 (b.zw), p2 (c.x, c.w); not translated/rotated
  triangle: {
    code: 4,
    fields: [f("x1", 4, CO), f("y1", 5, CO), f("x2", 6, CO), f("y2", 7, CO), f("x3", 8, CO), f("y3", 11, CO)],
  },
  // center + radius
  hexagon: {code: 5, fields: [f("x", 4, CO), f("y", 5, CO), f("r", 8, SIZE, 0.4)]},
  // center + radius + inner ratio (point sharpness)
  star: {code: 6, fields: [f("x", 4, CO), f("y", 5, CO), f("r", 8, SIZE, 0.4), f("inner", 9, UNIT, 0.4)]},
}
