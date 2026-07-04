// Zigzag — a Joy Division "Unknown Pleasures" waterfall: stacked waveform
// ridgelines receding in perspective, with hidden-line removal so front peaks
// occlude the lines behind them. White ridges on black by default. Shares the
// prelude's uniform/binding contract.
//
// Per pixel we march the rows front→back keeping a running silhouette (the
// highest ridge crest seen so far at this column); a row's line only draws where
// it pokes above that silhouette — that's the hidden-line removal.
import {WGSL_PRELUDE} from "./prelude.wgsl.js"

export const ZIGZAG_WGSL =
  WGSL_PRELUDE +
  /* wgsl */ `
@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
  let res = u.res.xy;
  let time = u.params.x * u.style.z;
  let intensity = u.params.y;
  let uv = in.uv;
  let sx = uv.x;
  let sy = uv.y;   // 0 = bottom (front rows), 1 = top (back rows / horizon)

  let flow = time * 0.6;   // how fast the waveforms travel
  var lit = 0.0;
  var glow = 0.0;
  var silhouette = -1.0;   // highest crest (max curveY) seen among front rows

  // Few, big rows: cheap enough for integrated GPUs and reads as a close camera.
  // One ridged-noise octave + a traveling sine keeps the per-row cost tiny.
  for (var i = 0; i < 22; i = i + 1) {
    let t = f32(i) / 21.0;                 // 0 = front (bottom), 1 = back (horizon)

    // Perspective trapezoid: back rows are narrower + bunched toward the horizon.
    let hw = mix(0.60, 0.34, t);
    let inWin = step(0.5 - hw, sx) * step(sx, 0.5 + hw);
    let ud = clamp((sx - (0.5 - hw)) / (2.0 * hw), 0.0, 1.0);   // data coord in the row

    // Activity concentrates at mid-depth and mid-width; edges lie flat.
    let depthEnv = exp(-5.0 * (t - 0.48) * (t - 0.48));
    let xEnv = smoothstep(0.0, 0.14, ud) * smoothstep(1.0, 0.86, ud);
    let env = depthEnv * xEnv;

    // Flowing jagged waveform: the ridged-noise domain SCROLLS with time and a
    // traveling sine rides through it, so every row undulates like a wave and
    // flickers like a flame instead of morphing in place.
    let r = 1.0 - abs(2.0 * noise(vec2<f32>(ud * 20.0 + flow, t * 10.0 - flow * 0.25)) - 1.0);
    let s = 0.5 + 0.5 * sin(ud * 26.0 - flow * 2.4 + t * 5.0);
    var wav = pow(clamp(r * 0.72 + s * 0.28, 0.0, 1.0), 2.1);

    let baseY = 0.05 + 0.68 * pow(t, 0.80);        // front near the bottom, filling the frame
    let heightScale = mix(0.55, 0.13, t);          // taller front peaks — closer camera
    let curveY = baseY + wav * env * heightScale * intensity;

    // Visible only where it pokes above the running front silhouette (and in-window).
    let visible = inWin * step(silhouette - 0.0004, curveY);
    let d = abs(sy - curveY);
    lit = max(lit, visible * smoothstep(0.0075, 0.0, d));
    glow = max(glow, visible * smoothstep(0.08, 0.0, d));

    silhouette = max(silhouette, mix(-2.0, curveY, inWin));
  }

  // Palette: colA = base, colC = ridge lines, colB = a faint under-glow.
  var col = u.colA.xyz;
  col = col + u.colB.xyz * glow * 0.25;
  col = mix(col, u.colC.xyz, lit);

  col = col + vec3<f32>(touch());
  col = bg_post(col, uv, res, time, u.post);
  return vec4<f32>(col, 1.0);
}
`
