// Where a right-click menu goes. Pure arithmetic, no DOM.
//
// Extracted rather than left inline (StudioContextMenu keeps the equivalent
// `place()` in the hook) for one reason: "the menu must never run off the edge
// of the window" is a claim about numbers, and a claim about numbers is cheap
// to assert here and impossible to assert from the LiveView test suite.
//
// The hook still owns the hard part — a `position: fixed` box resolves against
// the nearest transformed / filtered ancestor rather than the viewport, so the
// caller measures that offset itself and applies it to what this returns. This
// function only answers "where in the viewport should the box land".

// Anchored at the cursor, because that is what a context menu does everywhere
// else on the machine. Down-and-right by default; it flips to the other side of
// the pointer rather than being squashed against an edge, and clamps as a last
// resort so a menu taller than the window still starts on screen instead of
// above it.
export function menuPosition({point, size, viewport, margin = 8}) {
  const px = number(point && point.x)
  const py = number(point && point.y)
  const width = number(size && size.width)
  const height = number(size && size.height)
  const vw = number(viewport && viewport.width)
  const vh = number(viewport && viewport.height)

  const x = px + width > vw - margin ? px - width : px
  const y = py + height > vh - margin ? py - height : py

  return {
    x: clamp(x, margin, vw - width - margin),
    y: clamp(y, margin, vh - height - margin),
  }
}

// The low bound wins a fight with the high one: when the box does not fit at
// all, starting at the margin shows its first item, and starting at the other
// end shows nothing.
function clamp(value, low, high) {
  return Math.max(low, Math.min(value, Math.max(low, high)))
}

function number(value) {
  return Number.isFinite(value) ? value : 0
}
