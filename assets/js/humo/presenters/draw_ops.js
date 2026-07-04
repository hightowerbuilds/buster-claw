// Draw sanitizer — the trust boundary for a `humo-draw` block (HUMO screen
// rewrite, Phase 4). Turns an agent's shape list into a bounded, clamped list of
// normalized shapes the Canvas2D draw presenter renders. This is the rewrite of
// the retired SDF encoder: same schema idea (kinds, ops, clamped params, a hard
// shape cap, fail-closed diagnostics) but it targets Canvas2D draw ops, NOT a
// GPU storage buffer — the agent fills data, never code, and can't blow up the
// GPU. Pure and bun-tested; the canvas drawing itself is not.
import {clampR} from "../params.js"

export const MAX_SHAPES = 64

const KINDS = new Set(["circle", "box", "roundbox", "segment", "triangle", "hexagon", "star"])
// Boolean composites, mapped to Canvas2D globalCompositeOperation in draw.js.
const OPS = new Set(["union", "subtract", "intersect"])

const num = (v, d) => (typeof v === "number" && isFinite(v) ? v : d)
// Draw space is centered, ~[-1,1]; clamp a little beyond so composition has room
// but a stray value can't fling geometry off to infinity.
const co = (v, d = 0) => clampR(num(v, d), -2, 2)
const sz = (v, d) => clampR(num(v, d), 0, 2)
const unit = (v, d) => clampR(num(v, d), 0, 1)

function normalize(s, op) {
  const base = {kind: s.kind, op}
  switch (s.kind) {
    case "circle":
      return {...base, x: co(s.x), y: co(s.y), r: sz(s.r, 0.4)}
    case "box":
      return {...base, x: co(s.x), y: co(s.y), w: sz(s.w, 0.3), h: sz(s.h, 0.3)}
    case "roundbox":
      return {...base, x: co(s.x), y: co(s.y), w: sz(s.w, 0.3), h: sz(s.h, 0.3), radius: sz(s.radius, 0.05)}
    case "segment":
      return {...base, x1: co(s.x1), y1: co(s.y1), x2: co(s.x2), y2: co(s.y2), th: sz(s.th, 0.02)}
    case "triangle":
      return {...base, x1: co(s.x1), y1: co(s.y1), x2: co(s.x2), y2: co(s.y2), x3: co(s.x3), y3: co(s.y3)}
    case "hexagon":
      return {...base, x: co(s.x), y: co(s.y), r: sz(s.r, 0.4)}
    default: // star
      return {...base, x: co(s.x), y: co(s.y), r: sz(s.r, 0.4), inner: unit(s.inner, 0.4)}
  }
}

// Sanitize a shape list → {shapes, report}. `report` is fail-closed diagnostics
// (total / count / dropped / capped) so a truncation never reads as "drew it
// all" — same posture as the old encoder.
export function sanitizeShapes(shapes) {
  const list = Array.isArray(shapes) ? shapes : []
  const out = []
  const report = {total: list.length, count: 0, dropped: 0, capped: 0}

  for (const s of list) {
    if (!s || !KINDS.has(s.kind)) {
      report.dropped++
      continue
    }
    if (out.length >= MAX_SHAPES) {
      report.capped++
      continue
    }
    out.push(normalize(s, OPS.has(s.op) ? s.op : "union"))
  }

  report.count = out.length
  return {shapes: out, report}
}
