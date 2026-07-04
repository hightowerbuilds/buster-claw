// The smoke shader — WGSL source of truth for the one pipeline that draws the
// ambient smoke background behind the homepage chat. As a background it is
// driven with no content and reveal/lens at 0, so the content/reveal/lens code
// below no-ops and it renders pure fbm smoke + the hi-fi post stack.
//
// This is the whole engine: a single fullscreen pass that draws an fbm smoke
// atmosphere and composites the *content texture* (chat type / diagrams /
// drawings, authored on Canvas2D) on top, revealed along a noise-dissolve
// threshold so content condenses out of the fog. Deliberately ONE pipeline fed
// by a uniform buffer + a texture — the pattern WKWebView's WebGPU is happy
// with. The hi-fi post stack (glow, film grain, scanlines, tonemap) folds in
// here in a later phase; for now this is the smoke atmosphere + content
// composite + the still-lens, ported from the original smoke.wgsl.
//
// Uniform layout — must mirror `struct U` (five vec4<f32> = 20 floats = 80
// bytes); see packUniforms in params.js:
//   res.xy    = canvas resolution in device pixels
//   params.x  = time (seconds)
//   params.y  = intensity (smoke density energy; the mapping layer drives this)
//   params.z  = reveal (0 = all smoke, 1 = content fully condensed)
//   params.w  = freezeTime — the timestamp the lens holds the smoke at
//   lens      = (x, y, radius, strength) — the hover "still lens": inside the
//               circle time freezes and the rim fringes chromatically.
//   mood      = (energy, temp -1 cool..+1 warm, density, _)
//   style     = (pixelCell 1=off, paletteAmt 0=off, _, _)
export const SMOKE_WGSL = /* wgsl */ `
struct U {
  res: vec4<f32>,
  params: vec4<f32>,
  lens: vec4<f32>,
  mood: vec4<f32>,   // energy, temp (-1 cool .. +1 warm), density, _
  style: vec4<f32>,  // pixelCell (1 = off), paletteAmt (0 = off), motion (1 = full), _
  post: vec4<f32>,   // glow, grain, scanline, vignette (the hi-fi post stack)
  colA: vec4<f32>,   // palette (rgb in .xyz): base, wisp accent, smoke body
  colB: vec4<f32>,
  colC: vec4<f32>,
};
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var smp: sampler;
@group(0) @binding(2) var contentTex: texture_2d<f32>;

// The 4-shade Game Boy DMG palette, darkest → lightest.
fn dmg(level: i32) -> vec3<f32> {
  if (level <= 0) { return vec3<f32>(0.059, 0.220, 0.059); }
  if (level == 1) { return vec3<f32>(0.188, 0.384, 0.188); }
  if (level == 2) { return vec3<f32>(0.545, 0.675, 0.059); }
  return vec3<f32>(0.608, 0.737, 0.059);
}

// ACES filmic tonemap (Narkowicz approximation) — rolls highlights off so the
// glow blooms smoothly instead of clipping; lifts low-mids, keeps blacks black.
fn aces(x: vec3<f32>) -> vec3<f32> {
  let a = 2.51;
  let b = 0.03;
  let c = 2.43;
  let d = 0.59;
  let e = 0.14;
  return clamp((x * (a * x + b)) / (x * (c * x + d) + e), vec3<f32>(0.0), vec3<f32>(1.0));
}

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

fn fbm(p: vec2<f32>) -> f32 {
  var value = 0.0;
  var amplitude = 0.5;
  var frequency = 1.0;
  var q = p;
  for (var octave = 0; octave < 6; octave = octave + 1) {
    value = value + amplitude * noise(q * frequency);
    frequency = frequency * 2.04;
    amplitude = amplitude * 0.52;
    q = mat2x2<f32>(0.80, -0.60, 0.60, 0.80) * q;
  }
  return value;
}

@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
  let res = u.res.xy;
  let time = u.params.x;
  let intensity = u.params.y;
  let reveal = u.params.z;
  let freeze_time = u.params.w;

  // Mood dressing (neutral = energy/density 0.5, temp 0 → base look unchanged).
  let energy = u.mood.x;
  let temp = u.mood.y;
  let density = u.mood.z;
  let e_drift = 0.4 + energy * 1.2;   // 0.5 → 1.0×
  let e_warp = 0.8 + energy * 0.4;    // 0.5 → 1.0×
  let dens = 0.6 + density * 0.8;     // 0.5 → 1.0×

  // Game Boy render mode: snap the sample point to a chunky pixel grid before
  // anything else, so the whole field (and the content sampled from it) is
  // blocky. pixelCell = 1 is a no-op at device resolution.
  let aspect = res.x / max(res.y, 1.0);
  let cell = max(u.style.x, 1.0);
  let uv = (floor(in.uv * res / cell) + vec2<f32>(0.5)) * cell / res;
  var p = vec2<f32>((uv.x - 0.5) * aspect, uv.y - 0.5);

  // The still lens: inside the hover circle, time is held at freeze_time —
  // every motion term flows through \`drift\`, so blending the clock per pixel
  // freezes the smoke (and the letters' shimmer) under the glass. Soft edge.
  let lens_vec = vec2<f32>((uv.x - u.lens.x) * aspect, uv.y - u.lens.y);
  let lens_r = length(lens_vec);
  let lens_amt = u.lens.w * smoothstep(u.lens.z, u.lens.z * 0.78, lens_r);
  let t = mix(time, freeze_time, lens_amt);

  // Higher noise frequencies shrink the billows; a stronger curl warp plus a
  // second, swapped-reuse warp pass (free — no extra fbm samples) pulls the
  // field into stringier, wispier filaments. Energy scales the drift (how fast
  // the smoke moves) and the curl warp (how turbulent).
  // motion (style.z) globally scales the smoke drift — reduced-motion calms it.
  let drift = t * 0.085 * e_drift * u.style.z;
  let curl_a = fbm(p * 3.1 + vec2<f32>(0.0, drift));
  let curl_b = fbm(p * 4.8 + vec2<f32>(drift * -0.7, 0.16));
  p = p + vec2<f32>(curl_a - 0.5, curl_b - 0.5) * 0.42 * e_warp;
  p = p + vec2<f32>(curl_b - 0.5, curl_a - 0.5) * 0.16 * e_warp;

  let smoke_low = fbm(p * 3.4 + vec2<f32>(0.0, drift * 1.6));
  let smoke_mid = fbm(p * 8.2 - vec2<f32>(drift * 1.3, 0.0));
  let smoke_fine = fbm(p * 17.0 + vec2<f32>(drift * 0.35, drift * -0.42));
  var smoke = smoke_low * 0.50 + smoke_mid * 0.32 + smoke_fine * 0.18;

  let vignette = smoothstep(0.98, 0.18, length((uv - vec2<f32>(0.5)) * vec2<f32>(aspect, 1.0)));
  let vertical_lift = smoothstep(-0.55, 0.62, p.y + smoke_low * 0.18);
  smoke = smoothstep(0.33, 0.84, smoke * vignette * vertical_lift);

  // Density scales how thick the smoke reads; temperature white-balances it
  // (warm → embery, cool → ashen blue), staying inside the Industrial palette.
  let tone = clamp(0.035 + smoke * 0.42 * intensity * dens, 0.0, 1.0);
  var col = mix(u.colA.xyz, u.colC.xyz, tone);
  col = vec3<f32>(col.r * (1.0 + 0.10 * temp), col.g, col.b * (1.0 - 0.10 * temp));

  // Content condenses from smoke — and stays *made of* smoke: the sample point
  // keeps a faint curl shimmer even when settled, a second offset "ghost"
  // sample smears each glyph like ink in air, and the fill density is modulated
  // by fine noise so strokes read as smoke, not solid paint. Hazard wisps in
  // the transition band.
  let tuv = vec2<f32>(in.uv.x, 1.0 - in.uv.y);
  let curl = vec2<f32>(curl_a - 0.5, curl_b - 0.5);
  // Two animated displacement terms: the big curl carries the content with the
  // smoke, the fine-field flutter makes every stroke tremble locally. Under the
  // lens (\`legible\`) both collapse to zero and the ghosts fade — the glass
  // reads the smoke: no waviness, no smear, full ink, crisp edges.
  let legible = lens_amt;
  let flut = vec2<f32>(smoke_mid - 0.5, smoke_fine - 0.5);
  let disp = (curl * (0.028 + 0.06 * (1.0 - reveal)) + flut * 0.014) * (1.0 - legible);
  // Chromatic aberration under the lens: red and blue core taps pull apart
  // radially, strongest toward the rim — glass fringing, no magnification.
  let radial = lens_vec / max(lens_r, 0.0001);
  let tdir = vec2<f32>(radial.x / max(aspect, 0.0001), -radial.y);
  let ca = 0.0038 * lens_amt * smoothstep(0.0, u.lens.z, lens_r);
  let ta_core = textureSample(contentTex, smp, tuv + disp).a;
  let ta_core_r = textureSample(contentTex, smp, tuv + disp + tdir * ca).a;
  let ta_core_b = textureSample(contentTex, smp, tuv + disp - tdir * ca).a;
  let ta_g1 = textureSample(contentTex, smp, tuv + disp * 2.6 + vec2<f32>(0.006, -0.008)).a;
  let ta_g2 = textureSample(contentTex, smp, tuv + disp * 4.0 + vec2<f32>(-0.008, 0.005)).a;
  let ghosts = (ta_g1 * 0.28 + ta_g2 * 0.17) * (1.0 - legible);
  let core_w = mix(0.55, 1.0, legible);
  let ta = ta_core * core_w + ghosts;
  let ta_r = ta_core_r * core_w + ghosts;
  let ta_b = ta_core_b * core_w + ghosts;
  // The lens also lifts reveal, so even mid-condense content reads under it.
  let rl = max(reveal, legible);
  let n = smoke_fine;
  // Blend the noisy dissolve threshold toward a plain crisp edge under glass.
  let a = mix(smoothstep(n - 0.36, n + 0.12, ta * rl), smoothstep(0.30, 0.62, ta * rl), legible);
  let a_r = mix(smoothstep(n - 0.36, n + 0.12, ta_r * rl), smoothstep(0.30, 0.62, ta_r * rl), legible);
  let a_b = mix(smoothstep(n - 0.36, n + 0.12, ta_b * rl), smoothstep(0.30, 0.62, ta_b * rl), legible);
  let band = (smoothstep(n - 0.56, n - 0.36, ta * rl) - a) * (1.0 - legible);
  let ink = mix(0.62 + 0.38 * smoke_mid, 1.0, legible);
  let ash = vec3<f32>(0.956, 0.945, 0.918);
  col = vec3<f32>(
    mix(col.r, ash.r, a_r * ink),
    mix(col.g, ash.g, a * ink),
    mix(col.b, ash.b, a_b * ink)
  );
  col = col + u.colB.xyz * band * 0.5;

  // The lens rim: a thin ash ring with warm/cool fringes on either side —
  // reads as a loupe resting on the fog.
  let ring_w = 0.010;
  let ring = (1.0 - smoothstep(0.0, ring_w, abs(lens_r - u.lens.z))) * u.lens.w;
  let ring_warm = (1.0 - smoothstep(0.0, ring_w, abs(lens_r - u.lens.z + 0.006))) * u.lens.w;
  let ring_cool = (1.0 - smoothstep(0.0, ring_w, abs(lens_r - u.lens.z - 0.006))) * u.lens.w;
  col = col + ash * ring * 0.14;
  col = col + vec3<f32>(1.0, 0.35, 0.15) * ring_warm * 0.10;
  col = col + vec3<f32>(0.35, 0.55, 1.0) * ring_cool * 0.10;

  // --- Hi-fi post stack -------------------------------------------------
  // Glow: a soft emissive halo off the content, single-pass multi-tap (12 taps
  // on two rings). Follows reveal (rl) so it blooms as content condenses;
  // ash-tinted since content is authored white/alpha. textureSampleLevel keeps
  // it out of derivative/uniformity trouble.
  let glow_amt = u.post.x;
  if (glow_amt > 0.001) {
    var halo = 0.0;
    for (var gi = 0; gi < 12; gi = gi + 1) {
      let ga = f32(gi) * 0.5235988; // 30° steps
      let grad = select(0.022, 0.011, (gi % 2) == 0);
      let goff = vec2<f32>(cos(ga), sin(ga)) * grad;
      halo = halo + textureSampleLevel(contentTex, smp, tuv + goff, 0.0).a;
    }
    col = col + ash * (halo / 12.0) * rl * glow_amt * 0.85;
  }

  // Filmic tonemap so the glow rolls off smoothly rather than clipping.
  col = aces(col);

  // Post vignette: gently darken the screen edges.
  let pvig = smoothstep(1.15, 0.30, length((in.uv - vec2<f32>(0.5)) * vec2<f32>(aspect, 1.0)));
  col = col * mix(1.0, pvig, u.post.w);

  // Scanlines: soft horizontal lines in device space (~4px period).
  let scan = 0.5 + 0.5 * sin(in.uv.y * res.y * 1.57079633);
  col = col * (1.0 - u.post.z * (1.0 - scan));

  // Film grain: per-pixel animated luminance noise (the only animated post term;
  // reduced-motion drops post.grain to 0 hook-side).
  let gnoise = hash(in.uv * res + vec2<f32>(fract(time) * 431.0, fract(time * 1.37) * 197.0)) - 0.5;
  col = col + vec3<f32>(gnoise) * u.post.y;

  // Game Boy palette quantization: bucket luminance into the 4 DMG greens.
  // paletteAmt eases the whole reply between full-color smoke and retro green.
  let lum = clamp(dot(col, vec3<f32>(0.299, 0.587, 0.114)), 0.0, 0.999);
  let gb = dmg(i32(lum * 4.0));
  col = mix(col, gb, u.style.y);
  return vec4<f32>(col, 1.0);
}
`
