// sevenseg — a seven-segment countdown/clock readout for the Notify widget and
// (Phase 3) the fired-notification modal. Reads u.lens.x = remaining seconds and
// draws "DD:DD": MM:SS under an hour, HH:MM at or above one hour (clamped to
// 99:59). The colon blinks at ~1 Hz while counting seconds. Palette: colA =
// unlit background, colC = lit segment, colB = colon accent. Not a background —
// no content sampling; touch() keeps the unused bindings 1/2 alive.
import {WGSL_PRELUDE} from "./prelude.wgsl.js"
import {SEVENSEG_GLYPHS_WGSL} from "./sevenseg_glyphs.wgsl.js"

export const SEVENSEG_WGSL =
  WGSL_PRELUDE +
  SEVENSEG_GLYPHS_WGSL +
  /* wgsl */ `
@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
  let res = u.res.xy;
  let uv = in.uv;

  // Remaining seconds → DD:DD.
  let total = max(0, i32(floor(u.lens.x)));
  var left: i32;
  var right: i32;
  var seconds_mode = total < 3600;
  if (seconds_mode) {
    left = total / 60;
    right = total % 60;
  } else {
    left = min(99, total / 3600);
    right = (total % 3600) / 60;
  }
  var digits = array<i32, 4>(left / 10, left % 10, right / 10, right % 10);

  // Layout: work in a space where y in [0,1] and x in [0, aspect]; fit by height.
  let aspect = res.x / max(res.y, 1.0);
  let p = vec2<f32>(uv.x * aspect, uv.y);

  let digit_w = 0.46;
  let digit_h = 0.80;
  let colon_w = 0.28;
  let gap = 0.06;
  let total_w = 4.0 * digit_w + colon_w + 4.0 * gap;
  let x0 = (aspect - total_w) * 0.5;
  let y0 = (1.0 - digit_h) * 0.5;
  let aa = 1.5 / max(res.y, 1.0);

  var lit = 0.0;
  var ghost = 0.0;

  var cx = x0;
  for (var i = 0; i < 4; i = i + 1) {
    // The colon occupies the slot after the second digit.
    if (i == 2) {
      cx = cx + colon_w + gap;
    }
    let local = vec2<f32>((p.x - cx) / digit_w, (p.y - y0) / digit_h);
    if (local.x >= 0.0 && local.x <= 1.0 && local.y >= 0.0 && local.y <= 1.0) {
      let cov = digit_cov(local, digits[i], aa);
      lit = max(lit, cov.x);
      ghost = max(ghost, cov.y);
    }
    cx = cx + digit_w + gap;
  }

  // Colon between the two digit pairs; blinks while counting seconds.
  let colon_cx = x0 + 2.0 * digit_w + 2.0 * gap + colon_w * 0.5;
  let blink = select(1.0, step(fract(u.params.x), 0.5), seconds_mode);
  let dot_r = 0.05;
  let d_top = distance(p, vec2<f32>(colon_cx, y0 + digit_h * 0.62));
  let d_bot = distance(p, vec2<f32>(colon_cx, y0 + digit_h * 0.30));
  let colon = (smoothstep(dot_r + aa, dot_r - aa, d_top)
    + smoothstep(dot_r + aa, dot_r - aa, d_bot)) * blink;

  var col = u.colA.xyz;
  col = mix(col, u.colC.xyz, ghost * 0.12);              // faint unlit ghost
  col = mix(col, u.colC.xyz, lit);                       // lit digits
  col = mix(col, u.colB.xyz, clamp(colon, 0.0, 1.0));    // colon accent
  col = col + vec3<f32>(touch());
  return vec4<f32>(col, 1.0);
}
`
