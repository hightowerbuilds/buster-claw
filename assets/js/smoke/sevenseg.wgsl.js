// sevenseg — a seven-segment countdown/clock readout for the Notify widget and
// (Phase 3) the fired-notification modal. Reads u.lens.x = remaining seconds and
// draws "DD:DD": MM:SS under an hour, HH:MM at or above one hour (clamped to
// 99:59). The colon blinks at ~1 Hz while counting seconds. Palette: colA =
// unlit background, colC = lit segment, colB = colon accent. Not a background —
// no content sampling; touch() keeps the unused bindings 1/2 alive.
import {WGSL_PRELUDE} from "./prelude.wgsl.js"

export const SEVENSEG_WGSL =
  WGSL_PRELUDE +
  /* wgsl */ `
// Segment bitmask per digit (bit0=a top, 1=b, 2=c, 3=d, 4=e, 5=f, 6=g middle).
fn seg_mask(d: i32) -> u32 {
  var masks = array<u32, 10>(63u, 6u, 91u, 79u, 102u, 109u, 125u, 7u, 127u, 111u);
  return masks[clamp(d, 0, 9)];
}

// Coverage of a horizontal bar: x in [x0,x1], centered at y=cy, half-thickness t.
fn hbar(p: vec2<f32>, x0: f32, x1: f32, cy: f32, t: f32, aa: f32) -> f32 {
  let ix = smoothstep(x0 - aa, x0 + aa, p.x) * smoothstep(x1 + aa, x1 - aa, p.x);
  let iy = smoothstep(cy - t - aa, cy - t + aa, p.y) * smoothstep(cy + t + aa, cy + t - aa, p.y);
  return ix * iy;
}

// Coverage of a vertical bar: y in [y0,y1], centered at x=cx, half-thickness t.
fn vbar(p: vec2<f32>, cx: f32, y0: f32, y1: f32, t: f32, aa: f32) -> f32 {
  let ix = smoothstep(cx - t - aa, cx - t + aa, p.x) * smoothstep(cx + t + aa, cx + t - aa, p.x);
  let iy = smoothstep(y0 - aa, y0 + aa, p.y) * smoothstep(y1 + aa, y1 - aa, p.y);
  return ix * iy;
}

// Digit d at cell-space point p ([0,1]^2, y-up). Returns (lit, all): lit is the
// coverage of this digit's segments, all is every segment (for a faint ghost).
fn digit_cov(p: vec2<f32>, d: i32, aa: f32) -> vec2<f32> {
  let t = 0.075;
  let ml = 0.16;
  let mr = 0.84;
  let yb = 0.10;
  let ym = 0.50;
  let yt = 0.90;
  var seg = array<f32, 7>(
    hbar(p, ml, mr, yt, t, aa),   // a top
    vbar(p, mr, ym, yt, t, aa),   // b top-right
    vbar(p, mr, yb, ym, t, aa),   // c bottom-right
    hbar(p, ml, mr, yb, t, aa),   // d bottom
    vbar(p, ml, yb, ym, t, aa),   // e bottom-left
    vbar(p, ml, ym, yt, t, aa),   // f top-left
    hbar(p, ml, mr, ym, t, aa)    // g middle
  );
  let mask = seg_mask(d);
  var lit = 0.0;
  var all = 0.0;
  for (var i = 0; i < 7; i = i + 1) {
    all = max(all, seg[i]);
    if ((mask & (1u << u32(i))) != 0u) {
      lit = max(lit, seg[i]);
    }
  }
  return vec2<f32>(lit, all);
}

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
