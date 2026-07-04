// Aurora — an alternative homepage background: drifting fbm-warped curtains of
// teal→violet light over a near-black sky, with sparse static stars. Shares the
// prelude's uniform/binding contract so it runs through createSmoke unchanged.
import {WGSL_PRELUDE} from "./prelude.wgsl.js"

export const AURORA_WGSL =
  WGSL_PRELUDE +
  /* wgsl */ `
@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
  let res = u.res.xy;
  let time = u.params.x * u.style.z;   // motion scale (reduced-motion calms it)
  let intensity = u.params.y;
  let aspect = res.x / max(res.y, 1.0);
  let uv = in.uv;
  let p = vec2<f32>((uv.x - 0.5) * aspect, uv.y - 0.5);

  // Curtains: warp the field, then draw drifting vertical bands, brighter low
  // on the screen and fading toward the top.
  let warp = fbm(p * 2.0 + vec2<f32>(0.0, time * 0.05));
  let band = fbm(vec2<f32>(p.x * 3.0 + warp * 0.6, p.y * 1.5 - time * 0.08));
  let curtain = smoothstep(0.35, 0.85, band) * smoothstep(1.0, 0.15, uv.y);

  // Palette: colA = sky base, colB = low curtain, colC = high curtain.
  let glow = mix(u.colB.xyz, u.colC.xyz, clamp(uv.y, 0.0, 1.0));

  var col = u.colA.xyz;
  col = col + glow * curtain * intensity * 0.9;

  let star = step(0.997, hash(floor(uv * res / 2.5))) * smoothstep(0.3, 1.0, uv.y);
  col = col + vec3<f32>(star) * 0.35;

  col = col + vec3<f32>(touch());
  col = bg_post(col, uv, res, time, u.post);
  return vec4<f32>(col, 1.0);
}
`
