// Lava — an alternative homepage background: a churning, domain-warped fbm heat
// field mapped through a black→red→orange→yellow molten palette. Shares the
// prelude's uniform/binding contract so it runs through createSmoke.
import {WGSL_PRELUDE} from "./prelude.wgsl.js"

export const LAVA_WGSL =
  WGSL_PRELUDE +
  /* wgsl */ `
@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
  let res = u.res.xy;
  let time = u.params.x * u.style.z;
  let intensity = u.params.y;
  let aspect = res.x / max(res.y, 1.0);
  let uv = in.uv;
  let p = vec2<f32>((uv.x - 0.5) * aspect, uv.y - 0.5);

  // Domain-warp the field with itself, drifting, for a slow molten churn.
  let warp = vec2<f32>(
    fbm(p * 2.0 + vec2<f32>(0.0, time * 0.10)),
    fbm(p * 2.0 + vec2<f32>(5.2, time * 0.08 + 1.3))
  );
  var heat = fbm(p * 3.0 + warp * 1.4 - vec2<f32>(0.0, time * 0.05));
  heat = heat + 0.5 * fbm(p * 6.0 + warp * 0.8 + vec2<f32>(time * 0.03, 0.0));
  heat = clamp(heat * intensity * 1.1, 0.0, 1.0);

  // Molten palette: near-black → deep red → orange → yellow-white.
  let c1 = vec3<f32>(0.05, 0.01, 0.01);
  let c2 = vec3<f32>(0.55, 0.06, 0.02);
  let c3 = vec3<f32>(0.95, 0.35, 0.05);
  let c4 = vec3<f32>(1.00, 0.85, 0.45);
  var col = mix(c1, c2, smoothstep(0.15, 0.45, heat));
  col = mix(col, c3, smoothstep(0.45, 0.70, heat));
  col = mix(col, c4, smoothstep(0.70, 0.95, heat));

  col = col + vec3<f32>(touch());
  col = bg_post(col, uv, res, time, u.post);
  return vec4<f32>(col, 1.0);
}
`
