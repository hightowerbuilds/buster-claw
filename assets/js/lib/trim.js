// Pure geometry for the Studio's drag-to-select (SOUND_STUDIO_ROADMAP Phase 3).
//
// Separated from the hook for the same reason `dtmf.js` is: this is arithmetic
// that decides what gets cut out of someone's audio, and arithmetic you can
// only exercise by dragging a mouse is arithmetic nobody tests. The hook keeps
// the DOM; this keeps the maths.

// A drag shorter than this is a click — someone dismissing the selection, not
// asking for a 4 ms one.
export const MIN_SELECTION_MS = 20

// Where along a clip a pointer landed. Ratios outside the element clamp to its
// ends, which is what makes "drag past the edge to select to the end" work.
export function msAtRatio(ratio, durationMs) {
  if (!(durationMs > 0)) return 0
  const clamped = Math.min(1, Math.max(0, ratio))
  return clamped * durationMs
}

// Normalized as the drag happens, so dragging leftward from the anchor behaves
// exactly like dragging rightward instead of producing an inverted selection
// that every downstream consumer would have to re-order.
export function selection(anchorMs, atMs) {
  return {from: Math.min(anchorMs, atMs), to: Math.max(anchorMs, atMs)}
}

export function isMeaningful({from, to}) {
  return to - from >= MIN_SELECTION_MS
}

// Overlay geometry as percentages: how much to shade off each end, and where
// the two edge markers sit. Returned together because they must agree — an
// edge drawn from one rounding and a shade from another leaves a visible seam.
export function overlay({from, to}, durationMs) {
  if (!(durationMs > 0)) return {left: 0, right: 0, edgeA: 0, edgeB: 0}

  const pct = (ms) => Math.min(100, Math.max(0, (ms / durationMs) * 100))
  return {left: pct(from), right: pct(durationMs - to), edgeA: pct(from), edgeB: pct(to)}
}
