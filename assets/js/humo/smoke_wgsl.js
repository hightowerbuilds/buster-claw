// Humo's smoke shader — WGSL source of truth (Phase 0.2, HUMO_ROADMAP.md).
//
// Ported near-verbatim from Luke's gemma-construct/shaders/smoke.wgsl (6-octave
// fbm + curl-style domain warp + vignette + vertical lift), verified in the
// shell's WKWebView by the Phase 0.1 spike (Path A: WebGPU). On top of the
// field sits the Phase 2 mechanism: a text texture displaced by the curl warp
// and revealed along a noise dissolve threshold — "text condenses from smoke".
// Hazard-orange wisps (#FF4D1C) live in the transition band; body tones are
// Industrial Claw ash-on-near-black.
//
// Uniform layout (three vec4s, 48 bytes — see packUniforms in params.js):
//   res.xy    = canvas resolution in device pixels
//   params.x  = time (seconds)
//   params.y  = intensity (smoke density energy; the mapping layer drives this)
//   params.z  = reveal (0 = all smoke, 1 = text fully condensed)
//   params.w  = freezeTime — the timestamp the lens holds the smoke at
//   lens      = (x, y, radius, strength) — the hover "still lens": inside the
//               circle time freezes and the rim fringes chromatically, like a
//               magnifying glass that magnifies nothing.
export const SMOKE_WGSL = /* wgsl */ `
struct U {
  res: vec4<f32>,
  params: vec4<f32>,
  lens: vec4<f32>,
};
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var smp: sampler;
@group(0) @binding(2) var textTex: texture_2d<f32>;

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

  let aspect = res.x / max(res.y, 1.0);
  let uv = in.uv;
  var p = vec2<f32>((uv.x - 0.5) * aspect, uv.y - 0.5);

  // The still lens: inside the hover circle, time is held at freeze_time —
  // every motion term flows through \`drift\`, so blending the clock per pixel
  // freezes the smoke (and the letters' shimmer) under the glass. Soft edge.
  let lens_vec = vec2<f32>((uv.x - u.lens.x) * aspect, uv.y - u.lens.y);
  let lens_r = length(lens_vec);
  let lens_amt = u.lens.w * smoothstep(u.lens.z, u.lens.z * 0.78, lens_r);
  let t = mix(time, freeze_time, lens_amt);

  // Tuned 07-03 ("smaller + more smokey"): higher noise frequencies shrink the
  // billows; a stronger curl warp plus a second, swapped-reuse warp pass (free —
  // no extra fbm samples) pulls the field into stringier, wispier filaments.
  let drift = t * 0.085;
  let curl_a = fbm(p * 3.1 + vec2<f32>(0.0, drift));
  let curl_b = fbm(p * 4.8 + vec2<f32>(drift * -0.7, 0.16));
  p = p + vec2<f32>(curl_a - 0.5, curl_b - 0.5) * 0.42;
  p = p + vec2<f32>(curl_b - 0.5, curl_a - 0.5) * 0.16;

  let smoke_low = fbm(p * 3.4 + vec2<f32>(0.0, drift * 1.6));
  let smoke_mid = fbm(p * 8.2 - vec2<f32>(drift * 1.3, 0.0));
  let smoke_fine = fbm(p * 17.0 + vec2<f32>(drift * 0.35, drift * -0.42));
  var smoke = smoke_low * 0.50 + smoke_mid * 0.32 + smoke_fine * 0.18;

  let vignette = smoothstep(0.98, 0.18, length((uv - vec2<f32>(0.5)) * vec2<f32>(aspect, 1.0)));
  let vertical_lift = smoothstep(-0.55, 0.62, p.y + smoke_low * 0.18);
  smoke = smoothstep(0.33, 0.84, smoke * vignette * vertical_lift);

  let tone = clamp(0.035 + smoke * 0.42 * intensity, 0.0, 1.0);
  var col = mix(vec3<f32>(0.055, 0.055, 0.055), vec3<f32>(0.956, 0.945, 0.918), tone);

  // Text condenses from smoke — and stays *made of* smoke: the sample point
  // keeps a faint curl shimmer even when settled (letters never go flat), a
  // second offset "ghost" sample smears each glyph like ink in air, and the
  // fill density is modulated by fine noise so strokes read as smoke, not
  // solid paint. Hazard wisps in the transition band.
  let tuv = vec2<f32>(in.uv.x, 1.0 - in.uv.y);
  let curl = vec2<f32>(curl_a - 0.5, curl_b - 0.5);
  // Two animated displacement terms: the big curl carries the letters with the
  // smoke, the fine-field flutter makes every stroke tremble locally.
  let flut = vec2<f32>(smoke_mid - 0.5, smoke_fine - 0.5);
  let disp = curl * (0.028 + 0.06 * (1.0 - reveal)) + flut * 0.014;
  // Three taps — core plus two spread ghosts — smear each glyph into the air.
  // Chromatic aberration under the lens: red and blue core taps pull apart
  // radially, strongest toward the rim — glass fringing, no magnification.
  let radial = lens_vec / max(lens_r, 0.0001);
  let tdir = vec2<f32>(radial.x / max(aspect, 0.0001), -radial.y);
  let ca = 0.0038 * lens_amt * smoothstep(0.0, u.lens.z, lens_r);
  let ta_core = textureSample(textTex, smp, tuv + disp).a;
  let ta_core_r = textureSample(textTex, smp, tuv + disp + tdir * ca).a;
  let ta_core_b = textureSample(textTex, smp, tuv + disp - tdir * ca).a;
  let ta_g1 = textureSample(textTex, smp, tuv + disp * 2.6 + vec2<f32>(0.006, -0.008)).a;
  let ta_g2 = textureSample(textTex, smp, tuv + disp * 4.0 + vec2<f32>(-0.008, 0.005)).a;
  let ghosts = ta_g1 * 0.28 + ta_g2 * 0.17;
  let ta = ta_core * 0.55 + ghosts;
  let ta_r = ta_core_r * 0.55 + ghosts;
  let ta_b = ta_core_b * 0.55 + ghosts;
  let n = smoke_fine;
  let a = smoothstep(n - 0.36, n + 0.12, ta * reveal);
  let a_r = smoothstep(n - 0.36, n + 0.12, ta_r * reveal);
  let a_b = smoothstep(n - 0.36, n + 0.12, ta_b * reveal);
  let band = smoothstep(n - 0.56, n - 0.36, ta * reveal) - a;
  let ink = 0.62 + 0.38 * smoke_mid;
  let ash = vec3<f32>(0.956, 0.945, 0.918);
  col = vec3<f32>(
    mix(col.r, ash.r, a_r * ink),
    mix(col.g, ash.g, a * ink),
    mix(col.b, ash.b, a_b * ink)
  );
  col = col + vec3<f32>(1.0, 0.302, 0.110) * band * 0.5;

  // The lens rim: a thin ash ring with warm/cool fringes on either side —
  // reads as a loupe resting on the fog.
  let ring_w = 0.010;
  let ring = (1.0 - smoothstep(0.0, ring_w, abs(lens_r - u.lens.z))) * u.lens.w;
  let ring_warm = (1.0 - smoothstep(0.0, ring_w, abs(lens_r - u.lens.z + 0.006))) * u.lens.w;
  let ring_cool = (1.0 - smoothstep(0.0, ring_w, abs(lens_r - u.lens.z - 0.006))) * u.lens.w;
  col = col + ash * ring * 0.14;
  col = col + vec3<f32>(1.0, 0.35, 0.15) * ring_warm * 0.10;
  col = col + vec3<f32>(0.35, 0.55, 1.0) * ring_cool * 0.10;
  return vec4<f32>(col, 1.0);
}
`
