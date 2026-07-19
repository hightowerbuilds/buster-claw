// keypad — a 3x4 telephone keypad for BusterPhone's Playback panel. Digits use
// the exact shared seven-segment geometry from the Notify timer/alarm shader;
// star and hash complete the familiar phone layout. A restrained breathing
// pulse keeps the panel alive without competing with the dialed-number readout.
import {WGSL_PRELUDE} from "./prelude.wgsl.js"
import {SEVENSEG_GLYPHS_WGSL} from "./sevenseg_glyphs.wgsl.js"

export const KEYPAD_WGSL =
  WGSL_PRELUDE +
  SEVENSEG_GLYPHS_WGSL +
  /* wgsl */ `
fn line_cov(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>, t: f32, aa: f32) -> f32 {
  let pa = p - a;
  let ba = b - a;
  let h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.0001), 0.0, 1.0);
  let d = length(pa - ba * h);
  return smoothstep(t + aa, t - aa, d);
}

fn star_cov(p: vec2<f32>, aa: f32) -> f32 {
  let t = 0.045;
  let vertical = line_cov(p, vec2<f32>(0.50, 0.18), vec2<f32>(0.50, 0.82), t, aa);
  let rising = line_cov(p, vec2<f32>(0.24, 0.32), vec2<f32>(0.76, 0.68), t, aa);
  let falling = line_cov(p, vec2<f32>(0.24, 0.68), vec2<f32>(0.76, 0.32), t, aa);
  return max(vertical, max(rising, falling));
}

fn hash_cov(p: vec2<f32>, aa: f32) -> f32 {
  let t = 0.038;
  var cov = line_cov(p, vec2<f32>(0.38, 0.18), vec2<f32>(0.38, 0.82), t, aa);
  cov = max(cov, line_cov(p, vec2<f32>(0.62, 0.18), vec2<f32>(0.62, 0.82), t, aa));
  cov = max(cov, line_cov(p, vec2<f32>(0.20, 0.39), vec2<f32>(0.80, 0.39), t, aa));
  return max(cov, line_cov(p, vec2<f32>(0.20, 0.61), vec2<f32>(0.80, 0.61), t, aa));
}

fn rounded_box_sdf(p: vec2<f32>, half_size: vec2<f32>, radius: f32) -> f32 {
  let q = abs(p) - half_size + vec2<f32>(radius);
  return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
  let res = u.res.xy;
  let uv = in.uv;
  let time = u.params.x;
  let aspect = res.x / max(res.y, 1.0);
  let p = vec2<f32>(uv.x * aspect, uv.y);

  // Keep the upper quarter open for the live dialed-number/contact readout.
  let keypad_h = 0.66;
  let keypad_w = min(aspect * 0.86, keypad_h * 0.78);
  let origin = vec2<f32>((aspect - keypad_w) * 0.5, 0.04);
  let grid = (p - origin) / vec2<f32>(keypad_w, keypad_h) * vec2<f32>(3.0, 4.0);

  let atmosphere = fbm(uv * vec2<f32>(3.0 * aspect, 3.0) + vec2<f32>(time * 0.025, 0.0));
  var col = mix(u.colA.xyz, u.colB.xyz, 0.018 + atmosphere * 0.025);

  if (grid.x >= 0.0 && grid.x < 3.0 && grid.y >= 0.0 && grid.y < 4.0) {
    let column = i32(floor(grid.x));
    let row = i32(floor(grid.y));
    let index = row * 3 + column;
    let cell = fract(grid);
    let cell_px = min(res.x * keypad_w / max(aspect * 3.0, 1.0), res.y * keypad_h / 4.0);
    let aa = 1.5 / max(cell_px, 1.0);

    // Bottom-up rows: * 0 # / 7 8 9 / 4 5 6 / 1 2 3.
    var keys = array<i32, 12>(10, 0, 11, 7, 8, 9, 4, 5, 6, 1, 2, 3);
    let symbol = keys[index];
    let breathe = 0.5 + 0.5 * sin(time * 0.72 + f32(index) * 0.83);

    let key_sdf = rounded_box_sdf(cell - vec2<f32>(0.5), vec2<f32>(0.40, 0.39), 0.11);
    let key_fill = smoothstep(aa, -aa, key_sdf);
    let key_inner = smoothstep(aa, -aa, key_sdf + 0.025);
    let key_border = clamp(key_fill - key_inner, 0.0, 1.0);

    let glyph_uv = (cell - vec2<f32>(0.33, 0.23)) / vec2<f32>(0.34, 0.54);
    var glyph = 0.0;
    var ghost = 0.0;
    if (symbol >= 0 && symbol <= 9) {
      let cov = digit_cov(glyph_uv, symbol, aa / 0.34);
      glyph = cov.x;
      ghost = cov.y;
    } else if (symbol == 10) {
      glyph = star_cov(cell, aa);
    } else {
      glyph = hash_cov(cell, aa);
    }

    col = mix(col, u.colB.xyz, key_fill * (0.035 + breathe * 0.025));
    col = mix(col, u.colB.xyz, key_border * 0.30);
    col = mix(col, u.colC.xyz, ghost * 0.055);
    col = mix(col, u.colC.xyz, glyph * (0.48 + breathe * 0.12));
  }

  col = bg_post(col, uv, res, time, u.post);
  col = col + vec3<f32>(touch());
  return vec4<f32>(col, 1.0);
}
`
