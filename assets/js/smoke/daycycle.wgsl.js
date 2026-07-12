// Daycycle — the Time & Place panel's sky. A portrait of the machine's own
// local time of day: the sun arcs over a graded sky with drifting clouds,
// wind streaks and a small flock of birds through daylight; dusk burns the
// horizon in the accent color; night goes dark with stars and a crescent
// moon. Time of day arrives as u.lens.x (0 = midnight, 0.5 = noon), fed each
// frame by the SmokeBackground hook when the mount carries data-daylight.
// Palette: colA night base, colB dawn/dusk glow, colC daylight.
// NOTE: no storage buffers (WKWebView), and never put a backtick in this file.
import {WGSL_PRELUDE} from "./prelude.wgsl.js"

export const DAYCYCLE_WGSL =
  WGSL_PRELUDE +
  /* wgsl */ `
fn sd_seg(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
  let pa = p - a;
  let ba = b - a;
  let h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
  return length(pa - ba * h);
}

@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
  let res = u.res.xy;
  let time = u.params.x * u.style.z;
  let intensity = u.params.y;
  let day = fract(u.lens.x);
  let aspect = res.x / max(res.y, 1.0);
  let uv = in.uv;
  let p = vec2<f32>((uv.x - 0.5) * aspect, uv.y - 0.5);

  // Sun elevation: 0 at 6am/6pm, +1 at noon, -1 at midnight.
  let ang = (day - 0.25) * 6.28318530718;
  let sun_el = sin(ang);
  let daylight = smoothstep(-0.12, 0.25, sun_el);
  let dusk = exp(-abs(sun_el) * 5.0);

  // Sky: night base up to daylight, warm horizon band at dawn and dusk.
  let horizon = 1.0 - uv.y;
  var col = mix(u.colA.xyz * 0.85, u.colC.xyz * (0.8 + 0.2 * uv.y), daylight);
  col = col + u.colB.xyz * dusk * horizon * horizon * 0.9;

  // Stars: quantized hash sparkle, twinkling, night only.
  let cell = floor((p + vec2<f32>(50.0)) * 60.0);
  let star_seed = hash(cell);
  let twinkle = 0.75 + 0.25 * sin(time * 2.0 + star_seed * 40.0);
  let star = pow(star_seed, 60.0) * twinkle * (1.0 - daylight);
  col = col + u.colC.xyz * star * 1.6;

  // Sun: arcs left to right through the daylight hours.
  let arc_t = clamp((day - 0.25) * 2.0, 0.0, 1.0);
  let sun_pos = vec2<f32>((arc_t - 0.5) * aspect * 0.9, sun_el * 0.42 - 0.06);
  let sun_d = length(p - sun_pos);
  let sun_core = smoothstep(0.055, 0.045, sun_d) * daylight;
  let sun_glow = exp(-sun_d * 6.0) * daylight * 0.5;
  col = mix(col, u.colC.xyz * 1.15 + u.colB.xyz * 0.25, sun_core);
  col = col + u.colB.xyz * sun_glow;

  // Moon: takes the same arc at night, with a bite for the crescent.
  let night_t = clamp((fract(day + 0.5) - 0.25) * 2.0, 0.0, 1.0);
  let moon_pos = vec2<f32>((night_t - 0.5) * aspect * 0.9, -sun_el * 0.42 - 0.06);
  let moon_d = length(p - moon_pos);
  let bite_d = length(p - moon_pos - vec2<f32>(0.016, 0.008));
  let moon = smoothstep(0.04, 0.033, moon_d) * smoothstep(0.03, 0.04, bite_d);
  col = mix(col, u.colC.xyz * 0.9, moon * (1.0 - daylight));

  // Clouds: two fbm layers drifting on the wind; bright by day, slate at night.
  let wind = 0.02 + daylight * 0.05;
  let cl1 = fbm(vec2<f32>(p.x * 2.2 - time * wind, p.y * 4.5 + 3.7));
  let cl2 = fbm(vec2<f32>(p.x * 3.6 - time * wind * 1.7, p.y * 7.0 - 9.2));
  let cloud = smoothstep(0.55, 0.75, cl1 * 0.65 + cl2 * 0.35) * (0.25 + uv.y * 0.5);
  let cloud_col = mix(u.colA.xyz * 1.6, u.colC.xyz * 1.02, daylight);
  col = mix(col, cloud_col, cloud * (0.35 + 0.4 * daylight));

  // Wind: thin horizontal filaments raking across, daylight-hours only.
  let streak = fbm(vec2<f32>(p.x * 1.6 - time * 0.3, p.y * 22.0));
  let wind_line = smoothstep(0.62, 0.78, streak) * daylight * 0.12;
  col = col + u.colC.xyz * wind_line;

  // Birds: a small flock of flapping v-glyphs crossing through daylight.
  if (daylight > 0.35) {
    for (var i = 0; i < 5; i = i + 1) {
      let fi = f32(i);
      let seed = hash(vec2<f32>(fi * 3.7, 11.3));
      let bx = (fract(time * (0.012 + seed * 0.01) + seed) - 0.5) * aspect * 1.3;
      let by = 0.06 + seed * 0.24 + 0.015 * sin(time * 0.6 + seed * 20.0);
      let bp = p - vec2<f32>(bx, by);
      let flap = 0.5 + 0.45 * sin(time * (5.0 + seed * 3.0) + seed * 40.0);
      let span = 0.016;
      let lift = span * (0.9 * flap - 0.25);
      let wing_l = sd_seg(bp, vec2<f32>(0.0), vec2<f32>(-span, lift));
      let wing_r = sd_seg(bp, vec2<f32>(0.0), vec2<f32>(span, lift));
      let bird = smoothstep(0.0035, 0.0015, min(wing_l, wing_r));
      col = mix(col, u.colA.xyz * 0.6, bird * daylight * 0.9);
    }
  }

  col = col * (0.75 + 0.35 * intensity);
  col = col + vec3<f32>(touch());
  col = bg_post(col, uv, res, time, u.post);
  return vec4<f32>(col, 1.0);
}
`
