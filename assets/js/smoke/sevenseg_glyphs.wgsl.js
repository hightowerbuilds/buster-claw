// Shared seven-segment glyph primitives. Both the Notify countdown and the
// BusterPhone keypad compile this exact WGSL, so a digit has one geometry and
// one mask table everywhere it appears.
export const SEVENSEG_GLYPHS_WGSL = /* wgsl */ `
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
`
