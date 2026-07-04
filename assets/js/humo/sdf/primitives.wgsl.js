// Humo's SDF primitive vocabulary — the start of our own in-app drawing library
// (HUMO_EXPRESSION_ROADMAP.md, Phase 1). These 2D signed-distance functions are
// ported from Inigo Quilez's public reference, whose *code snippets* are MIT
// (https://iquilezles.org/articles/distfunctions2d/). Attribution kept here per
// MIT. They are origin-centered; the interpreter (pass.wgsl.js) applies each
// shape's translate + rotate before calling them.
//
// Convention: d < 0 inside, d = 0 on the edge, d > 0 outside. Combine with the
// operators (union = min, subtract = max(-a,b), intersect = max, smooth = smin).
export const SDF_PRIMITIVES_WGSL = /* wgsl */ `
fn rot2(a: f32) -> mat2x2<f32> {
  let c = cos(a);
  let s = sin(a);
  return mat2x2<f32>(c, s, -s, c);
}

// Smooth-union: the operator that makes SDFs *blend* into organic forms.
fn smin(a: f32, b: f32, k: f32) -> f32 {
  let h = clamp(0.5 + 0.5 * (b - a) / max(k, 1e-5), 0.0, 1.0);
  return mix(b, a, h) - k * h * (1.0 - h);
}

fn sdCircle(p: vec2<f32>, r: f32) -> f32 {
  return length(p) - r;
}

fn sdBox(p: vec2<f32>, b: vec2<f32>) -> f32 {
  let d = abs(p) - b;
  return length(max(d, vec2<f32>(0.0))) + min(max(d.x, d.y), 0.0);
}

fn sdRoundBox(p: vec2<f32>, b: vec2<f32>, r: f32) -> f32 {
  let q = abs(p) - b + vec2<f32>(r);
  return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

fn sdSegment(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>, th: f32) -> f32 {
  let pa = p - a;
  let ba = b - a;
  let h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  return length(pa - ba * h) - th;
}

fn sdTriangle(p: vec2<f32>, p0: vec2<f32>, p1: vec2<f32>, p2: vec2<f32>) -> f32 {
  let e0 = p1 - p0;
  let e1 = p2 - p1;
  let e2 = p0 - p2;
  let v0 = p - p0;
  let v1 = p - p1;
  let v2 = p - p2;
  let pq0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
  let pq1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
  let pq2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
  let s = sign(e0.x * e2.y - e0.y * e2.x);
  let d = min(
    min(
      vec2<f32>(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
      vec2<f32>(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))
    ),
    vec2<f32>(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x))
  );
  return -sqrt(d.x) * sign(d.y);
}

fn sdHexagon(p_in: vec2<f32>, r: f32) -> f32 {
  let k = vec3<f32>(-0.866025404, 0.5, 0.577350269);
  var p = abs(p_in);
  p = p - 2.0 * min(dot(k.xy, p), 0.0) * k.xy;
  p = p - vec2<f32>(clamp(p.x, -k.z * r, k.z * r), r);
  return length(p) * sign(p.y);
}

fn sdStar5(p_in: vec2<f32>, r: f32, rf: f32) -> f32 {
  let k1 = vec2<f32>(0.809016994375, -0.587785252292);
  let k2 = vec2<f32>(-k1.x, k1.y);
  var p = p_in;
  p.x = abs(p.x);
  p = p - 2.0 * max(dot(k1, p), 0.0) * k1;
  p = p - 2.0 * max(dot(k2, p), 0.0) * k2;
  p.x = abs(p.x);
  p.y = p.y - r;
  let ba = rf * vec2<f32>(-k1.y, k1.x) - vec2<f32>(0.0, 1.0);
  let h = clamp(dot(p, ba) / dot(ba, ba), 0.0, r);
  return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
}
`
