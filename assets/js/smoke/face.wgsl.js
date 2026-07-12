// Face — the contact "shaderface": a head condensed out of the smoke, with
// glowing eyes that blink and a seeded expression, so every contact gets a
// distinct, deterministic face. Shares the prelude's uniform/binding contract
// (runs through createSmoke unchanged).
//
// Seed contract (used by the ShaderFace hook, free channels for backgrounds):
//   u.lens.x — the contact's seed, 0..1. Everything about the face (eye
//              spacing/size, mouth curve, head proportions, palette lean)
//              derives from it. Custom face shaders written to
//              <workspace>/shaders/ get the same uniform and should read it
//              the same way.
import {WGSL_PRELUDE} from "./prelude.wgsl.js"

export const FACE_WGSL =
  WGSL_PRELUDE +
  /* wgsl */ `
fn feat(seed: f32, k: f32) -> f32 {
  return fract(sin(seed * 78.233 + k * 37.719) * 43758.5453);
}

@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
  let res = u.res.xy;
  let time = u.params.x * u.style.z;
  let aspect = res.x / max(res.y, 1.0);
  let uv = in.uv;
  let p = vec2<f32>((uv.x - 0.5) * aspect, uv.y - 0.52);

  let seed = u.lens.x * 10.0 + 1.0;

  // Seeded physiognomy.
  let headR = 0.27 + 0.05 * feat(seed, 6.0);
  let eyeSpan = 0.10 + 0.07 * feat(seed, 1.0);
  let eyeY = 0.05 + 0.06 * feat(seed, 2.0);
  let eyeR = 0.030 + 0.022 * feat(seed, 3.0);
  let mouthW = 0.09 + 0.09 * feat(seed, 4.0);
  let smile = (feat(seed, 5.0) - 0.30) * 0.5; // mostly smiles, some skeptics
  let mouthY = -0.11 - 0.05 * feat(seed, 8.0);

  // The head: a soft blob whose edge is eaten by drifting smoke.
  let wob = fbm(p * 3.0 + vec2<f32>(seed, seed * 1.7) + vec2<f32>(time * 0.05, time * -0.03));
  let d = length(p * vec2<f32>(1.0, 1.06)) - headR - 0.06 * (wob - 0.5);
  let head = smoothstep(0.015, -0.03, d);
  let rim = smoothstep(0.07, 0.0, abs(d)) * 0.6;

  // Blink: open nearly always, snapping shut for ~6% of a slow cycle,
  // phase-offset by seed so a contact wall never blinks in unison.
  let cyc = abs(fract(time * 0.11 + feat(seed, 7.0)) - 0.5) * 2.0;
  let open = clamp((cyc - 0.06) * 18.0, 0.08, 1.0);

  // Eyes: glowing ellipses squashed by the blink, dark pupils.
  var glow = 0.0;
  var pupil = 0.0;
  for (var s = -1.0; s <= 1.0; s = s + 2.0) {
    let q = (p - vec2<f32>(s * eyeSpan, eyeY)) * vec2<f32>(1.0, 1.0 / open);
    let e = length(q) - eyeR;
    glow = glow + smoothstep(0.025, -0.005, e);
    pupil = pupil + smoothstep(0.004, -0.004, length(q) - eyeR * 0.42);
  }

  // Mouth: a parabolic stroke; the sign of smile decides the mood.
  let mq = p - vec2<f32>(0.0, mouthY);
  let curve = smile * ((mq.x * mq.x) / max(mouthW, 0.001) - mouthW * 0.5);
  let stroke = abs(mq.y - curve);
  let xmask = smoothstep(mouthW, mouthW * 0.7, abs(mq.x));
  let mouth = smoothstep(0.014, 0.004, stroke) * xmask * head;

  // Compose: ambient smoke, head body lit by colB, features in colC.
  var col = u.colA.xyz;
  let ambient = fbm(p * 2.2 - vec2<f32>(time * 0.04, 0.0) + seed * 3.7);
  col = col + u.colB.xyz * ambient * 0.22;
  col = col + u.colB.xyz * head * 0.30 + u.colB.xyz * rim * 0.55;
  col = col + u.colC.xyz * glow * 1.1;
  col = col - vec3<f32>(0.9) * pupil * glow * 0.6;
  col = col + u.colC.xyz * mouth * 0.85;

  col = col + vec3<f32>(touch());
  col = bg_post(col, uv, res, time, u.post);
  return vec4<f32>(col, 1.0);
}
`
