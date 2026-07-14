// Weather — an evolving homepage background that simulates a slowly changing
// sky. Two modes, blended by u.params.w (the hook eases it 0→1 when real
// conditions arrive over bc:sky):
//
//   Demo (params.w = 0, no location set): a ~2-minute clock drifts through
//   conditions that overlap and blend — sunny → windy → rain + lightning →
//   snow, looping back — under a fixed clear-afternoon light.
//
//   Live (params.w → 1): the sky is the user's place, right now. Slot map
//   (mirrored in smoke_background.js):
//     u.lens.x = local day fraction there (0 midnight, 0.5 noon)
//     u.lens.y / u.lens.z = sunrise / sunset as day fractions
//     u.lens.w = cloud cover 0..1
//     u.mood.x = rain, u.mood.y = thunder, u.mood.z = snow (0..1)
//     u.style.y = wind 0..1
//   Daylight follows the real sunrise/sunset (with a twilight shoulder); the
//   sun arcs between them, the moon takes the night leg, stars come out, and
//   dawn/dusk warm the horizon.
//
// Shares the prelude's uniform/binding contract (fbm/hash/grad3 come from it).
// Heavy — domain-warped clouds + depth-layered precipitation per pixel — so it
// renders low-res as an ambient background (see smoke_background.js).
// Rain/snow/lightning blocks are gated behind uniform `if`s (their amounts
// depend only on uniforms/time, so the branch is coherent) to keep clear
// stretches cheap.
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
  // Local position relative to this flake's (swaying) center.
  let p = f - vec2<f32>(jx * 0.7 + sx, jy * 0.7);
  let r = length(p);
  // Six-fold snowflake instead of a round orb: reach is the arm length as a
  // function of angle — long on the six axes, short between them — plus a tiny
  // solid hub so the center never drops out. Each flake spins on its own phase.
  let a = atan2(p.y, p.x) + phase;
  let c6 = cos(a * 6.0);
  let mainArm = pow(max(c6, 0.0), 3.0);           // 6 long arms on the axes
  let minorArm = pow(max(-c6, 0.0), 6.0);         // 6 short arms between them
  let reach = fsz * (0.20 + 0.85 * mainArm + 0.28 * minorArm);
  let star = smoothstep(reach, reach * 0.4, r);
  let hub = smoothstep(fsz * 0.30, fsz * 0.12, r);
  return max(star, hub) * present;
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
  let live = clamp(u.params.w, 0.0, 1.0);
  let aspect = res.x / max(res.y, 1.0);
  let uv = in.uv;
  let sUv = uv * vec2<f32>(aspect, 1.0);   // aspect-corrected for round flakes

  // Demo clock — one full cycle of pretend conditions ≈ 2 minutes.
  let ph = fract(time * 0.008);
  let gust = fbm(vec2<f32>(time * 0.09, 3.0));               // irregular 0→1 wind

  // Condition amounts: the demo clock's overlapping bumps, crossfaded toward
  // the real amounts (already eased by the hook) as live rises.
  let sunBump = wbump(ph, 0.10, 0.16);                       // demo clear spell
  let dWind = clamp(wbump(ph, 0.16, 0.24) + 0.12 + gust * 0.15, 0.0, 1.0);
  let rainAmt = mix(wbump(ph, 0.44, 0.16), clamp(u.mood.x, 0.0, 1.0), live);
  let boltAmt = mix(wbump(ph, 0.50, 0.12), clamp(u.mood.y, 0.0, 1.0), live);
  let snowAmt = mix(wbump(ph, 0.80, 0.15), clamp(u.mood.z, 0.0, 1.0), live);
  let windAmt = clamp(mix(dWind, u.style.y + gust * 0.15, live), 0.0, 1.0);
  let storminess = clamp(max(rainAmt, boltAmt), 0.0, 1.0);
  let coverAmt = mix(0.2 + 0.8 * storminess, clamp(u.lens.w, 0.0, 1.0), live);

  // Time & light. Demo pretends a fixed clear afternoon (noon, sun 6→6), so
  // everything below is a no-op until live rises; live tracks the place's real
  // clock and sun window. tw is the twilight shoulder (~45 min).
  let day = fract(mix(0.5, u.lens.x, live));
  let sr = mix(0.25, u.lens.y, live);
  let ss = mix(0.75, u.lens.z, live);
  let tw = 0.03;
  let dayl = smoothstep(sr - tw, sr + tw, day) * (1.0 - smoothstep(ss - tw, ss + tw, day));
  let dusk = wbump(day, sr, 0.05) + wbump(day, ss, 0.05);
  // How lit the world is: clouds/precipitation dim toward, not to, black.
  let lightLvl = mix(1.0, mix(0.28, 1.0, dayl), live);

  // Sun visibility: the demo's periodic clear spell, or real daylight thinned
  // by real cloud cover.
  let sunAmt = mix(sunBump, dayl * (1.0 - coverAmt * 0.85), live);

  // Sky: a vertical gradient that darkens and flattens under storm, sinks to
  // near-black at night, and warms at the horizon through dawn/dusk.
  let sky_horizon = mix(u.colA.xyz, u.colB.xyz, 0.35);
  let sky_zenith = u.colA.xyz;
  var sky = mix(sky_horizon, sky_zenith, smoothstep(0.0, 1.0, uv.y));
  sky = sky * mix(1.0, 0.4, storminess);
  sky = sky * mix(1.0, mix(0.10, 1.0, dayl), live);
  // Sunny spell warms and brightens the whole sky toward the highlight tone.
  sky = mix(sky, mix(sky, u.colC.xyz, 0.12) * 1.12, sunAmt);
  let horizonW = (1.0 - uv.y) * (1.0 - uv.y);
  let duskCol = mix(u.colB.xyz, u.colC.xyz, 0.4);
  sky = sky + duskCol * dusk * horizonW * 0.7 * live * (1.0 - coverAmt * 0.6);
  var col = sky;

  // Stars: quantized hash sparkle, twinkling, live nights only. Drawn under
  // the clouds so heavy cover swallows them naturally.
  let starAmt = (1.0 - dayl) * live;
  if (starAmt > 0.001) {
    let cellS = floor((sUv + vec2<f32>(50.0)) * 60.0);
    let sSeed = hash(cellS);
    let twinkle = 0.75 + 0.25 * sin(time * 2.0 + sSeed * 40.0);
    col = col + u.colC.xyz * pow(sSeed, 60.0) * twinkle * starAmt * 1.5;
  }

  // Moon: crosses the night leg (sunset → next sunrise) on the sun's arc, a
  // crescent via an offset bite. Under the clouds, like the stars.
  if (starAmt > 0.001) {
    let nSpan = max(fract(sr - ss), 0.05);
    let nt = clamp(fract(day - ss) / nSpan, 0.0, 1.0);
    let moonPos = vec2<f32>(mix(0.12, 0.88, nt) * aspect, 0.18 + 0.68 * sin(nt * 3.14159265));
    let mD = length(sUv - moonPos);
    let biteD = length(sUv - moonPos - vec2<f32>(0.02, 0.01));
    let moon = smoothstep(0.045, 0.036, mD) * smoothstep(0.033, 0.045, biteD);
    col = mix(col, u.colC.xyz * 0.9, moon * starAmt);
  }

  // Clouds: domain-warped fbm for a volumetric shape, with an internal detail
  // pass for fake lighting. Faster + heavier with wind/storm; pool toward top.
  let windSpeed = 0.05 + windAmt * 0.45 + storminess * 0.55 + gust * 0.2;
  let cUv = vec2<f32>(uv.x * 2.2 + time * windSpeed, uv.y * 1.7 - time * 0.02);
  let warp = fbm(cUv + vec2<f32>(time * 0.03, 0.0));
  let cloud = fbm(cUv + warp * 0.6);
  let detail = fbm(cUv * 2.3 + 4.0);
  let cover = smoothstep(0.42, 0.9, cloud) * coverAmt * (0.3 + 0.7 * uv.y);
  let lit = mix(u.colB.xyz, u.colA.xyz, 0.25);
  let cloudCol = mix(lit * 0.55, lit, detail) * mix(1.0, 0.55, storminess) * lightLvl;
  col = mix(col, cloudCol, clamp(cover, 0.0, 1.0));

  // Wispy streaks — the tell of a windy but otherwise clear day.
  let wisp = fbm(vec2<f32>(uv.x * 2.0 + time * (windSpeed * 2.0 + 0.3), uv.y * 7.0));
  col = mix(col, cloudCol, smoothstep(0.62, 0.92, wisp) * windAmt * 0.22);

  // Sun: a warm glowing disk — fixed high in the demo sky, arcing from real
  // sunrise to real sunset when live. Drawn after the clouds and occluded by
  // their cover, so it dims when clouds drift across.
  if (sunAmt > 0.001) {
    let arc = clamp((day - sr) / max(ss - sr, 0.02), 0.0, 1.0);
    let livePos = vec2<f32>(mix(0.12, 0.88, arc) * aspect, 0.18 + 0.68 * sin(arc * 3.14159265));
    let sunPos = mix(vec2<f32>(0.72 * aspect, 0.82), livePos, live);
    let glow = sun_at(sUv, sunPos, time) * sunAmt;
    let occl = 1.0 - clamp(cover, 0.0, 1.0);
    let sunCol = mix(u.colC.xyz, u.colB.xyz, 0.18);
    col = col + sunCol * glow * occl;
  }

  // Rain: three slanted depth layers falling fast. Rain is near-vertical when
  // calm; slant grows with wind/gusts. Near layer is bright + sparse, far
  // layers are fainter + denser for a receding veil. Dimmer at night.
  if (rainAmt > 0.001) {
    let slant = 0.05 + windAmt * 0.32 + gust * 0.12;
    let rainCol = mix(u.colB.xyz, u.colC.xyz, 0.45);
    let r0 = rain_layer(uv, time, 130.0, slant, 2.6, 0.09);
    let r1 = rain_layer(uv * 1.5 + vec2<f32>(0.3, 0.0), time, 220.0, slant, 2.1, 0.06);
    let r2 = rain_layer(uv * 2.3 + vec2<f32>(0.7, 0.0), time, 360.0, slant, 1.7, 0.04);
    let rain = (r0 * 0.55 + r1 * 0.4 + r2 * 0.28) * rainAmt * intensity;
    col = col + rainCol * rain * mix(0.45, 1.0, lightLvl);
  }

  // Snow: three drifting depth layers — near flakes big/soft, far ones tiny.
  // Night snow shows as a dimmer gray rather than full-bright highlight.
  if (snowAmt > 0.001) {
    let s0 = snow_layer(sUv, time, 18.0, 1.2, 0.28, 0.20);
    let s1 = snow_layer(sUv + vec2<f32>(5.0, 0.0), time, 30.0, 0.85, 0.2, 0.13);
    let s2 = snow_layer(sUv + vec2<f32>(11.0, 0.0), time, 48.0, 0.6, 0.14, 0.08);
    let snow = (s0 + s1 * 0.7 + s2 * 0.5) * snowAmt * intensity;
    col = mix(col, u.colC.xyz * mix(0.5, 1.0, lightLvl), clamp(snow, 0.0, 1.0));
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
