// Pure pointer maths for the Studio's multi-track arranger
// (SOUND_STUDIO_ROADMAP Phase 6). Same split as `trim.js` and `dtmf.js`: this
// decides where a clip lands in someone's arrangement, and arithmetic you can
// only exercise by dragging a mouse is arithmetic nobody tests.
//
// Deliberately only three functions. Ruler length, clip positions, and tick
// marks are all computed server-side and arrive as rendered markup or data
// attributes — duplicating that geometry here would be the same formula in two
// languages, free to drift apart.

// Where along the ruler a pointer landed. Clamped, so dragging past either edge
// of a track pins to its ends instead of producing an off-ruler position.
export function msAtRatio(ratio, viewMs) {
  if (!(viewMs > 0)) return 0
  return Math.min(1, Math.max(0, ratio)) * viewMs
}

// A press that barely moved is a click, not a drag — it selects the clip so
// copy, paste, and delete have something to act on. The slop is generous
// because a pointer wobbles by a pixel or two on the way up, and a selection
// that only works when you hold perfectly still is a selection that feels
// broken.
const CLICK_SLOP_PX = 4

export function isClick(dx, dy) {
  return Math.abs(dx) < CLICK_SLOP_PX && Math.abs(dy) < CLICK_SLOP_PX
}

// Where a dragged clip starts. The grab offset is the distance from the clip's
// start to where the pointer took hold, so a block grabbed by its middle does
// not snap its left edge to the cursor.
export function dropStartMs(pointerMs, grabOffsetMs) {
  return Math.max(0, pointerMs - grabOffsetMs)
}

// Which track row a pointer is over. Rows are tested against their own bounds
// rather than by dividing the container, because a pointer in the gap between
// two rows must still choose one — landing on a border is not a cancel.
export function trackIndexAt(clientY, rects) {
  if (!rects || rects.length === 0) return -1

  for (let i = 0; i < rects.length; i++) {
    if (clientY >= rects[i].top && clientY <= rects[i].bottom) return i
  }

  // Past either end, clamp to the nearest track: dragging above the first row or
  // below the last is a clear intent.
  return clientY < rects[0].top ? 0 : rects.length - 1
}
