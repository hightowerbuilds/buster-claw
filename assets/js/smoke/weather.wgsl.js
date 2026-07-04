// Weather — an evolving homepage background that simulates a slowly changing
// sky. A ~2-minute clock drifts through conditions that overlap and blend:
// sunny → windy → rain + lightning → snow, looping back to sunny. Each is a smooth
// periodic "bump" over the clock, so transitions are gradual rather than
// switched. Shares the prelude's uniform/binding contract (fbm/hash/grad3 come
// from it). Heavy — domain-warped clouds + depth-layered precipitation per
// pixel — so it renders low-res as an ambient background (see
// smoke_background.js). Rain/snow/lightning blocks are gated behind uniform
// `if`s (their amounts depend only on time, so the branch is coherent) to keep
// clear stretches cheap.
//
// Palette: colA = sky, colB = cloud/rain, colC = highlight (snow, lightning).
import {WGSL_PRELUDE} from "./prelude.wgsl.js"

export const WEATHER_WGSL =
  WGSL_PRELUDE +
  /* wgsl */ `
// Periodic bump on the weather clock: 1 at center c, fading to 0 by width w,
// wrapping around the [0,1) cycle so conditions ease in and out.
fn wbump(ph: f32, c: f32, w: f32) -> f32 {
  let d = abs(fract(ph - c + 0.5) - 0.5);
  return smoothstep(w, 0.0, d);
}

// One depth layer of rain: many thin, slanted streaks with a bright leading
// head and a motion-blur tail. Each column carries discrete drops (a short
// streak then a gap), intermittent per segment (present) and varied in
// brightness, so it reads as falling rain rather than static lines. Returns
// coverage in [0,1].
fn rain_layer(uv: vec2<f32>, t: f32, cols: f32, slant: f32, speed: f32, thin: f32) -> f32 {
  var p = vec2<f32>(uv.x + slant * uv.y, uv.y);
  p.x = p.x * cols;
  let ix = floor(p.x);
  let fx = fract(p.x) - 0.5;
  let ch = hash(vec2<f32>(ix, 3.0));
  let sp = speed * mix(0.9, 1.3, hash(vec2<f32>(ix, 7.0)));
  let travel = p.y * 2.0 + t * sp + ch;                    // ~2 drops per height
  let seg = floor(travel);
  let yv = fract(travel);
  let present = step(0.45, hash(vec2<f32>(ix, seg)));
  let bright = mix(0.4, 1.0, hash(vec2<f32>(ix, seg + 0.5)));
  let streak = smoothstep(0.42, 0.0, yv);                  // head at yv=0, fade up
  let across = smoothstep(thin, 0.0, abs(fx));
  return across * streak * present * bright;
}

// One depth layer of snow: soft, size-varied flakes on a scrolling grid, each
// swaying on its own phase. Returns coverage in [0,1].
fn snow_layer(uv: vec2<f32>, t: f32, cells: f32, speed: f32, sway: f32, sz: f32) -> f32 {
  // uv.y is 0 at the bottom, 1 at the top, so +t makes the grid (and flakes)
  // drift downward over time.
  let gp = vec2<f32>(uv.x * cells, uv.y * cells + t * speed);
  let cell = floor(gp);
  let f = fract(gp) - 0.5;
  let present = step(0.5, hash(cell));
  let jx = hash(cell + vec2<f32>(1.0, 0.0)) - 0.5;
  let jy = hash(cell + vec2<f32>(0.0, 1.0)) - 0.5;
  let phase = hash(cell + vec2<f32>(3.0, 1.0)) * 6.2831853;
  let sx = sin(phase + t * 1.5) * sway;
  let fsz = sz * mix(0.45, 1.2, hash(cell + vec2<f32>(5.0, 2.0)));
  let d = length(f - vec2<f32>(jx * 0.7 + sx, jy * 0.7));
  return smoothstep(fsz, fsz * 0.2, d) * present;
}

// A jagged vertical lightning segment between y_bot and y_top, with a bright
// core and a soft glow. x0 is its column; the noise wobble makes it forked.
fn bolt_at(uv: vec2<f32>, x0: f32, seed: f32, y_top: f32, y_bot: f32, wob: f32, w: f32) -> f32 {
  let inside = step(y_bot, uv.y) * step(uv.y, y_top);
  let jag = (fbm(vec2<f32>(uv.y * 7.0 + seed, seed * 1.7)) - 0.5) * wob;
  let taper = w * mix(1.0, 0.4, smoothstep(y_top, y_bot, uv.y));
  let d = abs(uv.x - x0 - jag);
  let core = smoothstep(taper, 0.0, d);
  let glow = smoothstep(taper * 7.0, 0.0, d) * 0.3;
  return (core + glow) * inside;
}

// The sun: a crisp bright disk, a soft radial halo, and slowly-turning god-rays
// that fade with distance. pos/uv are aspect-corrected so the disk stays round.
// Returns additive light coverage (not clamped to 1 — the core can bloom).
fn sun_at(uv: vec2<f32>, pos: vec2<f32>, t: f32) -> f32 {
  let d = length(uv - pos);
  let disk = smoothstep(0.11, 0.085, d);                     // crisp core
  let halo = smoothstep(0.55, 0.0, d) * 0.5;                 // soft bloom
  let dir = uv - pos;
  let ang = atan2(dir.y, dir.x);
  let rays = (0.5 + 0.5 * sin(ang * 12.0 + t * 0.15)) * smoothstep(0.6, 0.05, d) * 0.22;
  return disk + halo + rays;
}

@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
  let res = u.res.xy;
  let time = u.params.x * u.style.z;
  let intensity = u.params.y;
  let aspect = res.x / max(res.y, 1.0);
  let uv = in.uv;
  let sUv = uv * vec2<f32>(aspect, 1.0);   // aspect-corrected for round flakes

  // Slow weather clock — one full cycle ≈ 2 minutes. Conditions overlap so the
  // sky is usually transitioning between two of them.
  let ph = fract(time * 0.008);
  let gust = fbm(vec2<f32>(time * 0.09, 3.0));               // irregular 0→1 wind
  let sunAmt = wbump(ph, 0.10, 0.16);                        // bright clear spell
  let windAmt = clamp(wbump(ph, 0.16, 0.24) + 0.12 + gust * 0.15, 0.0, 1.0);
  let rainAmt = wbump(ph, 0.44, 0.16);
  let boltAmt = wbump(ph, 0.50, 0.12);
  let snowAmt = wbump(ph, 0.80, 0.15);
  let storminess = clamp(max(rainAmt, boltAmt), 0.0, 1.0);

  // Sky: a vertical gradient that darkens and flattens under storm.
  let sky_horizon = mix(u.colA.xyz, u.colB.xyz, 0.35);
  let sky_zenith = u.colA.xyz;
  var sky = mix(sky_horizon, sky_zenith, smoothstep(0.0, 1.0, uv.y));
  sky = sky * mix(1.0, 0.4, storminess);
  // Sunny spell warms and brightens the whole sky toward the highlight tone.
  sky = mix(sky, mix(sky, u.colC.xyz, 0.12) * 1.12, sunAmt);
  var col = sky;

  // Clouds: domain-warped fbm for a volumetric shape, with an internal detail
  // pass for fake lighting. Faster + heavier with wind/storm; pool toward top.
  let windSpeed = 0.05 + windAmt * 0.45 + storminess * 0.55 + gust * 0.2;
  let cUv = vec2<f32>(uv.x * 2.2 + time * windSpeed, uv.y * 1.7 - time * 0.02);
  let warp = fbm(cUv + vec2<f32>(time * 0.03, 0.0));
  let cloud = fbm(cUv + warp * 0.6);
  let detail = fbm(cUv * 2.3 + 4.0);
  let cover = smoothstep(0.42, 0.9, cloud) * (0.2 + 0.8 * storminess) * (0.3 + 0.7 * uv.y);
  let lit = mix(u.colB.xyz, u.colA.xyz, 0.25);
  let cloudCol = mix(lit * 0.55, lit, detail) * mix(1.0, 0.55, storminess);
  col = mix(col, cloudCol, clamp(cover, 0.0, 1.0));

  // Wispy streaks — the tell of a windy but otherwise clear day.
  let wisp = fbm(vec2<f32>(uv.x * 2.0 + time * (windSpeed * 2.0 + 0.3), uv.y * 7.0));
  col = mix(col, cloudCol, smoothstep(0.62, 0.92, wisp) * windAmt * 0.22);

  // Sun: a warm glowing disk high in the sky during the clear spell. Drawn after
  // the clouds and occluded by their cover, so it dims when clouds drift across.
  if (sunAmt > 0.001) {
    let sunPos = vec2<f32>(0.72 * aspect, 0.82);
    let glow = sun_at(sUv, sunPos, time) * sunAmt;
    let occl = 1.0 - clamp(cover, 0.0, 1.0);
    let sunCol = mix(u.colC.xyz, u.colB.xyz, 0.18);
    col = col + sunCol * glow * occl;
  }

  // Rain: three slanted depth layers falling fast. Rain is near-vertical when
  // calm; slant grows with wind/gusts. Near layer is bright + sparse, far
  // layers are fainter + denser for a receding veil.
  if (rainAmt > 0.001) {
    let slant = 0.05 + windAmt * 0.32 + gust * 0.12;
    let rainCol = mix(u.colB.xyz, u.colC.xyz, 0.45);
    let r0 = rain_layer(uv, time, 130.0, slant, 2.6, 0.09);
    let r1 = rain_layer(uv * 1.5 + vec2<f32>(0.3, 0.0), time, 220.0, slant, 2.1, 0.06);
    let r2 = rain_layer(uv * 2.3 + vec2<f32>(0.7, 0.0), time, 360.0, slant, 1.7, 0.04);
    let rain = (r0 * 0.55 + r1 * 0.4 + r2 * 0.28) * rainAmt * intensity;
    col = col + rainCol * rain;
  }

  // Snow: three drifting depth layers — near flakes big/soft, far ones tiny.
  if (snowAmt > 0.001) {
    let s0 = snow_layer(sUv, time, 18.0, 1.2, 0.28, 0.20);
    let s1 = snow_layer(sUv + vec2<f32>(5.0, 0.0), time, 30.0, 0.85, 0.2, 0.13);
    let s2 = snow_layer(sUv + vec2<f32>(11.0, 0.0), time, 48.0, 0.6, 0.14, 0.08);
    let snow = (s0 + s1 * 0.7 + s2 * 0.5) * snowAmt * intensity;
    col = mix(col, u.colC.xyz, clamp(snow, 0.0, 1.0));
  }

  // Lightning: a per-window coin flip gated by boltAmt. On a strike, a double
  // flicker lights the sky (brightest near the bolt + up top) and a forked bolt
  // is drawn. Gated so most frames skip the extra fbm work.
  let seed = floor(time * 2.3);
  let strike = step(0.8, hash(vec2<f32>(seed, 9.0))) * boltAmt;
  if (strike > 0.001) {
    let fph = fract(time * 2.3);
    let flick = exp(-fph * 6.0) + 0.5 * exp(-fract(fph * 2.7) * 9.0);
    let boltX = 0.22 + 0.56 * hash(vec2<f32>(seed, 2.0));

    // Localized sky flash: stronger toward the top and near the bolt column.
    let nearBolt = smoothstep(0.55, 0.0, abs(uv.x - boltX));
    let flashCol = mix(u.colC.xyz, u.colB.xyz, 0.15);
    let skyGlow = flick * (0.25 + 0.75 * uv.y) * (0.4 + 0.6 * nearBolt) * strike;
    col = col + flashCol * skyGlow * 0.7;

    // Forked bolt: a main channel top→bottom plus a short branch off the middle.
    let main = bolt_at(uv, boltX, seed, 0.97, 0.06, 0.10, 0.0045);
    let branchX = boltX + (hash(vec2<f32>(seed, 4.0)) - 0.5) * 0.18;
    let branch = bolt_at(uv, branchX, seed + 13.0, 0.55, 0.12, 0.07, 0.003);
    col = col + u.colC.xyz * (main + branch * 0.6) * flick * strike * 1.6;
  }

  col = col + vec3<f32>(touch());
  col = bg_post(col, uv, res, time, u.post);
  return vec4<f32>(col, 1.0);
}
`
