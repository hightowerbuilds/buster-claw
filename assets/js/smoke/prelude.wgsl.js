// Shared WGSL prelude for the alternative homepage background shaders. It
// declares the SAME uniform + binding contract as smoke.wgsl.js (struct U at
// binding 0, a sampler at 1, a content texture at 2) so every design runs
// through createSmoke unchanged. The value-noise/fbm and ACES helpers are
// verbatim from the smoke shader; `bg_post` is the shared background post pass.
//
// Two kinds of background share this contract:
//
//   * A PLAIN background never samples content. `touch()` keeps bindings 1/2 in
//     the `layout:"auto"` pipeline at ~zero cost; it always returns 0.
//   * An IMAGE-REACTIVE background samples the user's selected background image
//     out of `contentTex` through `img()`/`img_lum()` and composites it itself
//     (the canvas is opaque — see IMAGE_SHADER_ROADMAP D1). It does not need
//     `touch()`: sampling for real keeps the bindings alive by itself.
//
// A shader is treated as image-reactive by the app precisely when its source
// calls this image API — derived from what it does, never from what it is
// called. Note that a WORKSPACE shader is the fs_main body ALONE, so it reaches
// the texture through `img()`/`img_lum()` and never writes `contentTex` itself;
// the marker has to match the helper calls, not the binding name. See
// `BusterClaw.Shaders.samples_image?/1`, which owns the authoritative pattern.
export const WGSL_PRELUDE = /* wgsl */ `
struct U {
  res: vec4<f32>,
  params: vec4<f32>,
  lens: vec4<f32>,
  mood: vec4<f32>,
  style: vec4<f32>,
  post: vec4<f32>,
  colA: vec4<f32>,   // the 3-color palette (rgb in .xyz): base, mid/accent, highlight
  colB: vec4<f32>,
  colC: vec4<f32>,
  imgSize: vec4<f32>, // .xy = image pixels (0 = no image), .zw = viewport pixels
  imgRect: vec4<f32>, // this canvas's rect within the viewport, as 0..1 fractions
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

// Keeps bindings 1+2 in the auto layout for a shader that never samples content.
// Always returns 0 — it is a layout keeper, not a signal.
fn touch() -> f32 {
  return textureSampleLevel(contentTex, smp, vec2<f32>(0.5, 0.5), 0.0).a * 0.0;
}

// --- the background image -------------------------------------------------
// 1.0 when the user has an image bound behind this shader, else 0.0. Fold every
// image-derived term through this so the shader still reads as a design when it
// is selected WITHOUT an image, instead of sampling an empty texture and drawing
// a dead rectangle.
fn has_img() -> f32 {
  return select(0.0, 1.0, u.imgSize.x > 0.0);
}

// Canvas uv -> image uv. ALWAYS go through this instead of sampling in.uv
// directly, which is wrong three ways at once and looks plausible while you
// write it:
//
//   1. Aspect. The canvas is the window's shape, the image is the photograph's.
//      Sampling raw uv stretches one onto the other. This cover-fits (fill,
//      preserve aspect, crop the overflow, centered).
//   2. Origin. vs_main emits uv with a BOTTOM-left origin; images are
//      top-left, so a raw sample lands upside down.
//   3. Split panes. The fit is computed against the VIEWPORT, not this canvas,
//      and offset by imgRect — so two joined terminals showing one picture
//      continue it across the seam instead of each drawing a whole copy. A
//      full-viewport canvas has imgRect = (0,0,1,1) and pays nothing for it.
fn img_uv(uv_in: vec2<f32>) -> vec2<f32> {
  let uv = vec2<f32>(uv_in.x, 1.0 - uv_in.y);
  let vp = u.imgRect.xy + uv * u.imgRect.zw;
  // No image, or a degenerate viewport: hand back viewport space rather than
  // dividing by zero (0/0 is NaN, and a NaN uv samples as black across the whole
  // frame). has_img() is how a shader SHOULD branch; this only keeps the math
  // finite for one that forgets to.
  if (u.imgSize.x <= 0.0 || u.imgSize.y <= 0.0 || u.imgSize.z <= 0.0 || u.imgSize.w <= 0.0) {
    return vp;
  }
  let img_aspect = u.imgSize.x / u.imgSize.y;
  let vp_aspect = u.imgSize.z / u.imgSize.w;
  var s = vec2<f32>(1.0, 1.0);
  if (img_aspect > vp_aspect) {
    s.x = vp_aspect / img_aspect;
  } else {
    s.y = img_aspect / vp_aspect;
  }
  return (vp - vec2<f32>(0.5)) * s + vec2<f32>(0.5);
}

// The image under this pixel. textureSampleLevel rather than textureSample
// so it is safe to call inside a branch — same reason touch() uses it.
fn img(uv: vec2<f32>) -> vec4<f32> {
  return textureSampleLevel(contentTex, smp, img_uv(uv), 0.0);
}

// Rec.709 luminance of the image under this pixel — the field most patterns want
// to be driven by (thin the veil over highlights, gather it in shadow).
fn img_lum(uv: vec2<f32>) -> f32 {
  return dot(img(uv).rgb, vec3<f32>(0.2126, 0.7152, 0.0722));
}

// 3-stop gradient: t=0 → a, 0.5 → b, 1 → c. The shaders map a scalar field
// through the user's / design's palette (u.colA/B/C).
fn grad3(t: f32, a: vec3<f32>, b: vec3<f32>, c: vec3<f32>) -> vec3<f32> {
  let x = clamp(t, 0.0, 1.0);
  let ab = mix(a, b, smoothstep(0.0, 0.5, x));
  return mix(ab, c, smoothstep(0.5, 1.0, x));
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
