// Waves — an alternative homepage background: slow topographic contour lines
// over an evolving fbm height field, in a cool blue ink on near-black. Shares
// the prelude's uniform/binding contract so it runs through createSmoke.
import {WGSL_PRELUDE} from "./prelude.wgsl.js"

export const WAVES_WGSL =
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

  // A slowly evolving height field; draw a line wherever it crosses a level.
  let h = fbm(p * 2.5 + vec2<f32>(time * 0.03, time * -0.02))
        + 0.5 * fbm(p * 5.0 - vec2<f32>(0.0, time * 0.05));
  let lines = abs(fract(h * 6.0) - 0.5);   // 0 on a contour, 0.5 between
  let contour = smoothstep(0.06, 0.0, lines);

  var col = vec3<f32>(0.03, 0.04, 0.06);
  let ink = vec3<f32>(0.35, 0.60, 0.90);
  col = col + ink * contour * intensity * 0.8;

  col = col + vec3<f32>(touch());
  col = bg_post(col, uv, res, time, u.post);
  return vec4<f32>(col, 1.0);
}
`
