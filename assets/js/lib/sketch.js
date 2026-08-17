// Geometry for the Sketch Pad — turning pointer events into the points a stroke
// is made of, and those points into an SVG path.
//
// Pure, and separate from the hook, for the same reason every other module in
// this directory is: the hook owns a live DOM, which a test cannot hold. What is
// worth testing is the arithmetic, and none of it needs one.
//
// SKETCH_ROADMAP Phase 1 replaced the canvas with SVG, so what used to live here
// (tool state, backing-store sizing, an eraser that painted the background) is
// gone rather than adapted. The server owns the document now; the toolbar is
// LiveView state; and an eraser that painted a colour would create ground-
// coloured ELEMENTS on a document — marks that look erased and are still there.

// Points closer together than this are dropped. A pointermove can fire per
// pixel, and a stroke made of every one of them is a `d` attribute of tens of
// kilobytes that has to cross the wire, land in a JSON file, and be diffed by
// LiveView on every change. At 1.5px the thinning is invisible and the saving is
// most of the stroke.
export const MIN_POINT_DISTANCE = 1.5

// Coordinates are rounded to match `BusterClaw.Sketch.Element`, which rounds on
// the way in. Without this the client draws a stroke at one precision and the
// server hands back another, and the line visibly shifts the moment it commits.
export function round1(n) {
  return Math.round(n * 10) / 10
}

// A pointer event in the surface's own coordinate space. One unit is one CSS
// pixel — the SVG viewBox tracks the panel size, so resizing reveals paper
// rather than scaling what is on it, and a stroke stays the size it was drawn.
export function toPoint(event, rect) {
  return [round1(event.clientX - rect.left), round1(event.clientY - rect.top)]
}

// Whether a point is far enough from the last one to be worth keeping.
export function shouldKeep(points, next, minDistance = MIN_POINT_DISTANCE) {
  if (!points || points.length === 0) return true

  const [lastX, lastY] = points[points.length - 1]
  const dx = next[0] - lastX
  const dy = next[1] - lastY

  return dx * dx + dy * dy >= minDistance * minDistance
}

// Append `next` to `points` if it earns its place. Returns the same array
// reference when it does not, so a caller can cheaply tell whether anything
// changed.
export function extend(points, next, minDistance = MIN_POINT_DISTANCE) {
  return shouldKeep(points, next, minDistance) ? [...points, next] : points
}

// Points to an SVG path.
//
// `BusterClaw.Sketch.Element`'s renderer produces the same string for the same
// points, and it has to: the hook draws a stroke while it is being made and the
// server draws it the instant it commits. A disagreement between the two is not
// a rendering bug, it is a visible jump at the end of every stroke. Both sides
// are tested against the same cases.
export function pathData(points) {
  if (!points || points.length === 0) return ""

  // A tap with no movement is a dot, not nothing. Zero-length paths do not
  // render even with a round linecap, so it gets an explicit second point.
  if (points.length === 1) {
    const [x, y] = points[0]
    return `M ${x} ${y} L ${x} ${y}`
  }

  const [first, ...rest] = points

  return `M ${first[0]} ${first[1]} ` + rest.map(([x, y]) => `L ${x} ${y}`).join(" ")
}
