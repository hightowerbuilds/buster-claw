// The SDF interpreter pass (HUMO_EXPRESSION_ROADMAP.md, Phase 1 — Path B).
// A fragment shader that walks a bounded storage buffer of shape instructions
// and writes the composed shape mask into the content texture the smoke shader
// already samples. The agent only ever fills this instruction buffer (via the
// validated `draw.js` encoder) — it never authors shader code, so the caps
// (MAX_SHAPES) and the schema are the whole trust boundary.
//
// Instruction layout per shape (three vec4, mirrors draw.js SHAPE_STRIDE):
//   a = (kind, op, smoothK, rotation)
//   b = (center.x, center.y, ptB.x, ptB.y)   // ptB used by segment/triangle
//   c = (size.x, size.y, size.z, ptC.y)       // meaning per kind (see draw.js)
//
// Draw space: origin centered, y up, x scaled by aspect. A circle of r=0.5 is
// half the surface height. This matches the smoke's y-flip so shapes render
// upright through the existing pipeline.
import {SDF_PRIMITIVES_WGSL} from "./primitives.wgsl.js"

export const SDF_PASS_WGSL = /* wgsl */ `
${SDF_PRIMITIVES_WGSL}

struct DrawU {
  res: vec4<f32>,   // xy = target resolution
  cfg: vec4<f32>,   // x = shape count, y = edge softness
};

struct Shape {
  a: vec4<f32>,
  b: vec4<f32>,
  c: vec4<f32>,
};

@group(0) @binding(0) var<uniform> du: DrawU;
@group(0) @binding(1) var<storage, read> shapes: array<Shape>;

struct VOut {
  @builtin(position) pos: vec4<f32>,
  @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> VOut {
  var p = array<vec2<f32>, 3>(
    vec2<f32>(-1.0, -3.0), vec2<f32>(-1.0, 1.0), vec2<f32>(3.0, 1.0));
  var o: VOut;
  o.pos = vec4<f32>(p[vi], 0.0, 1.0);
  o.uv = o.pos.xy * 0.5 + vec2<f32>(0.5);
  return o;
}

fn shape_dist(s: Shape, q: vec2<f32>) -> f32 {
  let kind = i32(s.a.x);
  if (kind == 3) {
    return sdSegment(q, s.b.xy, s.b.zw, s.c.x);
  }
  if (kind == 4) {
    return sdTriangle(q, s.b.xy, s.b.zw, vec2<f32>(s.c.x, s.c.w));
  }
  // Centered shapes: translate + rotate into local space first.
  let ql = rot2(-s.a.w) * (q - s.b.xy);
  if (kind == 0) { return sdCircle(ql, s.c.x); }
  if (kind == 1) { return sdBox(ql, s.c.xy); }
  if (kind == 2) { return sdRoundBox(ql, s.c.xy, s.c.z); }
  if (kind == 5) { return sdHexagon(ql, s.c.x); }
  return sdStar5(ql, s.c.x, s.c.y);
}

fn scene(q: vec2<f32>) -> f32 {
  let n = i32(du.cfg.x);
  var d = 1e9;
  for (var i = 0; i < n; i = i + 1) {
    let s = shapes[i];
    let di = shape_dist(s, q);
    let op = i32(s.a.y);
    if (op == 0) { d = min(d, di); }
    else if (op == 1) { d = max(d, -di); }
    else if (op == 2) { d = max(d, di); }
    else { d = smin(d, di, s.a.z); }
  }
  return d;
}

@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
  let aspect = du.res.x / max(du.res.y, 1.0);
  let q = vec2<f32>((in.uv.x - 0.5) * 2.0 * aspect, (in.uv.y - 0.5) * 2.0);
  let d = scene(q);
  let edge = max(du.cfg.y, 1e-4);
  let a = smoothstep(edge, -edge, d);  // 1 inside, 0 outside
  return vec4<f32>(a, a, a, a);
}
`
