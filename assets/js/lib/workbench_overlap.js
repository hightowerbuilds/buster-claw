import {leavesOf, panelGeometry} from "./workbench.js"

const clamp = (n, low, high) => Math.max(low, Math.min(high, n))
export function clampFrame(frame) {
  if (!frame || ![frame.x, frame.y, frame.width, frame.height].every(Number.isFinite)) return null
  const width = clamp(frame.width, .25, 1)
  const height = clamp(frame.height, .25, 1)
  return {x: clamp(frame.x, 0, 1 - width), y: clamp(frame.y, 0, 1 - height), width, height}
}
export function seedFrame(index) {
  const offset = (index % 4) * .08
  return {x: .04 + offset, y: .04 + offset, width: .7, height: .7}
}
export function workbenchGeometry(state, width, height) {
  if (state.mode !== "overlap" || state.zoom) return panelGeometry(state.tree, width, height, state.zoom)
  const panes = {}
  for (const [i, key] of leavesOf(state.tree).entries()) {
    const frame = clampFrame(state.frames?.[key]) || seedFrame(i)
    panes[key] = {x: frame.x * width, y: frame.y * height, width: frame.width * width, height: frame.height * height}
  }
  return {panes, dividers: []}
}
export function moveFrame(frame, dx, dy, width, height) {
  if (width <= 0 || height <= 0) return frame
  return clampFrame({...frame, x: frame.x + dx / width, y: frame.y + dy / height})
}
export function positionPane(el, box) {
  for (const key of ["x", "y", "width", "height"]) {
    if (Number.isFinite(box[key])) el.style.setProperty(`--pane-${key}`, `${box[key]}px`)
  }
}
