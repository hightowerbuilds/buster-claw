// Level metering maths for the recorder — pure, so it can be tested without a
// microphone, an AudioContext, or a browser (STUDIO_ROADMAP V.6).
//
// Two numbers off the same frames, because they answer different questions and
// neither substitutes for the other:
//
//   * PEAK, with a LATCHING clip indicator. A clip that flashes for 40 ms is
//     missed and the take is already ruined — digital clipping is unrecoverable,
//     so the indicator stays lit until it is deliberately cleared.
//   * RMS, for "am I loud enough". Peak alone is a bad guide to whether a
//     recording is usable: one stray transient can peak near full scale over a
//     take that is otherwise far too quiet to cut with.

// Everything is rendered on dBFS from -60 to 0. A linear meter spends most of
// its travel where the ear does not care.
export const FLOOR_DB = -60

// V.6's target: peaks -12 to -6 dBFS while speaking, nothing touching 0. The
// probe measured the existing corpus peaking at ~0.96, so headroom is the live
// risk here rather than level.
export const TARGET_LOW_DB = -12
export const TARGET_HIGH_DB = -6

// Amplitude (0..1) to dBFS. Silence is -Infinity mathematically, which cannot be
// rendered, so it floors — callers get a number they can position a bar with.
export function toDb(amplitude) {
  if (!(amplitude > 0)) return FLOOR_DB
  const db = 20 * Math.log10(amplitude)
  return db < FLOOR_DB ? FLOOR_DB : db
}

// dBFS to a 0..1 fraction of the meter's travel.
export function meterFraction(db) {
  if (!Number.isFinite(db)) return 0
  const clamped = Math.min(0, Math.max(FLOOR_DB, db))
  return (clamped - FLOOR_DB) / -FLOOR_DB
}

// Peak and RMS over one block of Float32 samples.
//
// `clipped` is true when a sample reached full scale. It is computed on the
// FLOATS as they arrive, because that is the last point at which the
// information exists: the int16 conversion downstream clamps, and a clamped
// sample is indistinguishable from one that was always at the rail.
export function analyse(samples) {
  let peak = 0
  let sumSquares = 0

  for (let i = 0; i < samples.length; i++) {
    const sample = samples[i]
    const magnitude = sample < 0 ? -sample : sample
    if (magnitude > peak) peak = magnitude
    sumSquares += sample * sample
  }

  const rms = samples.length ? Math.sqrt(sumSquares / samples.length) : 0
  return {peak, rms, clipped: peak >= 1.0}
}

// Which band a level sits in, for colouring the bar. `over` is its own band
// rather than the top of `good`, because "as loud as possible" and "too loud"
// look identical on a bar and mean opposite things.
export function band(db) {
  if (db >= 0) return "over"
  if (db >= TARGET_HIGH_DB) return "hot"
  if (db >= TARGET_LOW_DB) return "good"
  return "low"
}

// A latching peak hold. `hold` never falls on its own; `reset` is the only way
// down, which is what makes it a record of the take rather than a display of
// the moment.
export function createHold() {
  let hold = 0
  let clipped = false

  return {
    push(peak) {
      if (peak > hold) hold = peak
      if (peak >= 1.0) clipped = true
      return {hold, clipped}
    },
    reset() {
      hold = 0
      clipped = false
    },
    get value() {
      return {hold, clipped}
    },
  }
}
