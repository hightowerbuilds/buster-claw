// Mandelbrot — an alternative homepage background: the Mandelbrot set with a
// slow breathing zoom toward the seahorse-valley detail point, smooth-iteration
// escape bands cycled through the palette. The set interior is the base color;
// the exterior bands run colB→colC. Shares the prelude's uniform/binding
// contract so it runs through createSmoke. Heavy per-pixel iteration — rendered
// low-res as an ambient background (see smoke_background.js).
import {WGSL_PRELUDE} from "./prelude.wgsl.js"

export const MANDEL_WGSL =
  WGSL_PRELUDE +
  /* wgsl */ `
@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
  let res = u.res.xy;
  let time = u.params.x * u.style.z;
  let intensity = u.params.y;
  let aspect = res.x / max(res.y, 1.0);
  let uv = in.uv;
  var p = vec2<f32>((uv.x - 0.5) * aspect, uv.y - 0.5);

  // A very slow rotation keeps a still frame from feeling frozen.
  let a = time * 0.01;
  p = mat2x2<f32>(cos(a), -sin(a), sin(a), cos(a)) * p;

  // Breathing zoom toward a fixed detail point: oscillates wide↔close so it
  // never runs past float precision. exp(-1.6) ≈ 0.20 → zoom in [0.5, 2.5].
  let center = vec2<f32>(-0.743643887037151, 0.131825904205330);
  let zoom = 2.5 * exp(-1.6 * (0.5 - 0.5 * cos(time * 0.06)));
  let c = center + p * zoom;

  // Escape-time iteration with a generous bailout for smooth coloring.
  var z = vec2<f32>(0.0, 0.0);
  var iter = 0.0;
  var escaped = 0.0;
  for (var k = 0; k < 128; k = k + 1) {
    z = vec2<f32>(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
    if (dot(z, z) > 256.0) {
      escaped = 1.0;
      break;
    }
    iter = iter + 1.0;
  }

  var col = u.colA.xyz;   // interior of the set → base color
  if (escaped > 0.5) {
    // Smooth (fractional) iteration count → continuous bands, no stair-stepping.
    let mag = sqrt(max(dot(z, z), 1.0001));
    let nu = log(log(mag) / log(2.0)) / log(2.0);
    let mu = (iter + 1.0 - nu) / 128.0;
    let t = fract(mu * 3.0 + time * 0.03);   // cycle the palette outward + drift
    let bands = grad3(t, u.colB.xyz, u.colC.xyz, u.colB.xyz);
    // Fade the innermost reaches into the base for a soft edge, then let
    // intensity scale how strongly the fractal reads over the background.
    let edge = clamp(mu * 10.0, 0.0, 1.0);
    col = mix(u.colA.xyz, bands, edge * intensity);
  }

  col = col + vec3<f32>(touch());
  col = bg_post(col, uv, res, time, u.post);
  return vec4<f32>(col, 1.0);
}
`
