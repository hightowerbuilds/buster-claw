// Sky mapping — real conditions (WMO weather code, wind, cloud cover) → the
// amount knobs the weather shader's live mode consumes, plus the location's
// live time-of-day. Pure math, factored out of the SmokeBackground hook so bun
// can test it (this file plays the role params.js plays for the chat uniforms).
import {clamp01} from "./params.js"

// Per-code precipitation/thunder strengths. Codes absent here (clear, cloudy,
// fog) contribute no precipitation; cloud cover carries those looks.
const RAIN = {
  51: 0.2, 53: 0.3, 55: 0.45, 56: 0.35, 57: 0.4, // drizzle
  61: 0.45, 63: 0.65, 65: 0.9, 66: 0.55, 67: 0.65, // rain
  80: 0.5, 81: 0.7, 82: 1.0, // showers
  95: 0.7, 96: 0.75, 99: 0.85, // thunderstorms rain hard too
}
const SNOW = {71: 0.4, 73: 0.65, 75: 0.95, 77: 0.35, 85: 0.6, 86: 0.85}
const BOLT = {95: 0.7, 96: 0.85, 99: 1.0}

// {code, wind_mph, cloud_pct} (a bc:sky payload) → {rain, snow, bolt, cloud,
// wind}, each 0..1. Fog reads as a near-total veil; any precipitation implies
// cover even when the cloud reading lags behind the code.
export function skyAmounts({code, wind_mph, cloud_pct}) {
  const c = code ?? 0
  const rain = RAIN[c] ?? 0
  const snow = SNOW[c] ?? 0
  const bolt = BOLT[c] ?? 0
  let cloud = clamp01((cloud_pct ?? 50) / 100)
  if (c === 45 || c === 48) cloud = Math.max(cloud, 0.95)
  cloud = Math.max(cloud, rain * 0.8, snow * 0.8, bolt * 0.9)
  const wind = clamp01((wind_mph ?? 0) / 25)
  return {rain, snow, bolt, cloud, wind}
}

// Fraction of the day (0 = midnight, 0.5 = noon) at the location, from UTC
// epoch seconds and the location's UTC offset in seconds.
export function localDayFrac(utcSec, utcOffsetSec) {
  const s = (((utcSec + (utcOffsetSec || 0)) % 86400) + 86400) % 86400
  return s / 86400
}
