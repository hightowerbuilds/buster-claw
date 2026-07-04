// Shared WGSL prelude for the alternative homepage background shaders. It
// declares the SAME uniform + binding contract as smoke.wgsl.js (struct U at
// binding 0, a sampler at 1, a content texture at 2) so every design runs
// through createSmoke unchanged. Backgrounds never sample content — `touch()`
// keeps bindings 1/2 in the `layout:"auto"` pipeline at ~zero cost. The
// value-noise/fbm and ACES helpers are verbatim from the smoke shader; `bg_post`
// is the shared background post pass.
export const WGSL_PRELUDE = /* wgsl */ `
struct U {
  res: vec4<f32>,
  params: vec4<f32>,
  lens: vec4<f32>,
  mood: vec4<f32>,
  style: vec4<f32>,
  post: vec4<f32>,
};
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var smp: sampler;
@group(0) @binding(2) var contentTex: texture_2d<f32>;

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

fn hash(p: vec2<f32>) -> f32 {
  let h = dot(p, vec2<f32>(127.1, 311.7));
  return fract(sin(h) * 43758.5453123);
}

fn noise(p: vec2<f32>) -> f32 {
  let i = floor(p);
  let f = fract(p);
  let uu = f * f * (3.0 - 2.0 * f);
  let a = hash(i + vec2<f32>(0.0, 0.0));
  let b = hash(i + vec2<f32>(1.0, 0.0));
  let c = hash(i + vec2<f32>(0.0, 1.0));
  let d = hash(i + vec2<f32>(1.0, 1.0));
  return mix(mix(a, b, uu.x), mix(c, d, uu.x), uu.y);
}

fn fbm(p_in: vec2<f32>) -> f32 {
  var value = 0.0;
  var amplitude = 0.5;
  var frequency = 1.0;
  var q = p_in;
  for (var octave = 0; octave < 5; octave = octave + 1) {
    value = value + amplitude * noise(q * frequency);
    frequency = frequency * 2.04;
    amplitude = amplitude * 0.52;
    q = mat2x2<f32>(0.80, -0.60, 0.60, 0.80) * q;
  }
  return value;
}

fn aces(x: vec3<f32>) -> vec3<f32> {
  let a = 2.51;
  let b = 0.03;
  let c = 2.43;
  let d = 0.59;
  let e = 0.14;
  return clamp((x * (a * x + b)) / (x * (c * x + d) + e), vec3<f32>(0.0), vec3<f32>(1.0));
}

// Keeps bindings 1+2 in the auto layout (backgrounds never sample content).
fn touch() -> f32 {
  return textureSampleLevel(contentTex, smp, vec2<f32>(0.5, 0.5), 0.0).a * 0.0;
}

// Shared background post: tonemap + edge vignette + scanlines + film grain.
// post = (glow, grain, scanline, vignette); glow is foreground-only, ignored here.
fn bg_post(col_in: vec3<f32>, uv: vec2<f32>, res: vec2<f32>, time: f32, post: vec4<f32>) -> vec3<f32> {
  var col = aces(col_in);
  let aspect = res.x / max(res.y, 1.0);
  let vig = smoothstep(1.15, 0.30, length((uv - vec2<f32>(0.5)) * vec2<f32>(aspect, 1.0)));
  col = col * mix(1.0, vig, post.w);
  let scan = 0.5 + 0.5 * sin(uv.y * res.y * 1.57079633);
  col = col * (1.0 - post.z * (1.0 - scan));
  let g = hash(uv * res + vec2<f32>(fract(time) * 431.0, fract(time * 1.37) * 197.0)) - 0.5;
  col = col + vec3<f32>(g) * post.y;
  return col;
}
`
