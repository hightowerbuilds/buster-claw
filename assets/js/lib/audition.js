// Pure planning for the Studio's audition — hearing an arrangement without
// rendering it. Same split as `arrange.js` and `trim.js`: the hook performs,
// this decides, and what it decides is testable without an AudioContext.
//
// The DOM is the score. The server renders which tracks are audible and where
// every clip starts; these functions only read that shape. Audibility is NOT
// recomputed here — mute/solo semantics live in StudioAudio.audible?/2 and
// arrive as a data attribute, so the rules cannot drift between languages.

// Flatten the score into what actually plays: clips on audible tracks that
// have a resolvable source. A clip whose source vanished has no src and is
// skipped — the RENDER refuses loudly in that case (missing_source); the
// audition just plays what exists, because a preview that refuses to start
// over one dead reference can't be used to fix the arrangement around it.
export function auditionPlan(tracks) {
  const plays = []

  for (const track of tracks || []) {
    if (!track.audible) continue
    for (const clip of track.clips || []) {
      if (!clip.src) continue
      plays.push({src: clip.src, startMs: Math.max(0, clip.startMs || 0)})
    }
  }

  return plays
}

// Where the performance ends: the furthest clip's far edge, given each
// source's decoded duration. Mirrors StudioAudio.duration_ms/1, except real
// decoded lengths replace the cached layout widths.
export function planEndMs(plays, durationsBySrc) {
  let end = 0

  for (const play of plays || []) {
    const duration = (durationsBySrc && durationsBySrc.get(play.src)) || 0
    end = Math.max(end, play.startMs + duration)
  }

  return end
}

// How far along the playhead is, clamped: a stall never draws past the end,
// and a not-yet-started clock never draws before the beginning.
export function playheadRatio(elapsedMs, endMs) {
  if (!(endMs > 0)) return 1
  return Math.min(1, Math.max(0, elapsedMs / endMs))
}
