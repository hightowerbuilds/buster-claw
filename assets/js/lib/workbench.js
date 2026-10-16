// Geometry only. The LiveView owns the validated tree; flat, stable pane hosts
// preserve editors, streamed messages, and PTYs while their rectangles change.
export const WORKBENCH_STORAGE_KEY = "bc:workbench:v1"

export function panelGeometry(tree, width, height, zoom = null) {
  const panes = {}
  const dividers = []
  const gap = 8
  if (zoom) return {panes: {[zoom]: {x: 0, y: 0, width, height}}, dividers}

  const visit = (node, box, path) => {
    if (!node) return
    if (typeof node === "string") { panes[node] = box; return }
    const horizontal = node.axis === "horizontal"
    const size = horizontal ? box.width : box.height
    const gutter = Math.min(gap, size)
    const available = Math.max(0, size - gutter)
    const first = available * node.ratio
    const second = available - first
    const a = horizontal ? {...box, width: first} : {...box, height: first}
    const b = horizontal
      ? {...box, x: box.x + first + gutter, width: second}
      : {...box, y: box.y + first + gutter, height: second}
    const divider = horizontal
      ? {...box, x: box.x + first, width: gutter}
      : {...box, y: box.y + first, height: gutter}
    dividers.push({path, axis: node.axis, ratio: node.ratio, bounds: box, ...divider})
    visit(node.first, a, [...path, "first"])
    visit(node.second, b, [...path, "second"])
  }
  visit(tree, {x: 0, y: 0, width: Math.max(0, width), height: Math.max(0, height)}, [])
  return {panes, dividers}
}

export function resizeTree(tree, path, ratio) {
  if (!tree || typeof tree !== "object") return tree
  if (path.length === 0) return {...tree, ratio: Math.max(0.15, Math.min(0.85, ratio))}
  const [side, ...rest] = path
  if (side !== "first" && side !== "second") return tree
  return {...tree, [side]: resizeTree(tree[side], rest, ratio)}
}

export function layoutDots(tree) {
  return Object.values(panelGeometry(tree, 1000, 600).panes).map(box => ({
    x: (box.x + box.width / 2) / 10,
    y: (box.y + box.height / 2) / 6,
  }))
}

export function readLayout(storage) {
  try { return JSON.parse(storage.getItem(WORKBENCH_STORAGE_KEY)) } catch { return null }
}

export function saveLayout(storage, state) {
  try { storage.setItem(WORKBENCH_STORAGE_KEY, JSON.stringify(state)) } catch { /* A full store must not disable panes. */ }
}

// ---- Reordering -----------------------------------------------------------
// A dragged panel dropped on another's spot. The arrangement's SHAPE depends
// only on the count and the preset, so moving a panel is relabelling the
// tree's leaves in a new order — which is why the drag can preview locally and
// only the drop talks to the server.
export function leavesOf(tree) {
  if (!tree) return []
  if (typeof tree === "string") return [tree]
  return leavesOf(tree.first).concat(leavesOf(tree.second))
}

export function relabelTree(tree, order) {
  let i = 0
  const visit = node => {
    if (!node) return node
    if (typeof node === "string") return order[i++] ?? node
    return {...node, first: visit(node.first), second: visit(node.second)}
  }
  return visit(tree)
}

// Moving `key` onto `target`: the panels between them slide one slot toward
// the vacated spot, so the dragged panel ends up exactly where the target was.
export function reorderKeys(keys, key, target) {
  const from = keys.indexOf(key)
  const to = keys.indexOf(target)
  if (from === -1 || to === -1 || from === to) return keys
  const next = keys.slice()
  next.splice(from, 1)
  next.splice(to, 0, key)
  return next
}
