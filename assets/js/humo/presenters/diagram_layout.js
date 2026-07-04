// Pure layout for a `humo-graph` — nodes + directed edges → positioned boxes and
// edge segments (HUMO screen rewrite, Phase 2/3). Deterministic layered
// placement: columns by longest-path depth, rows evenly within a column, edges
// from a box's right border to the next's left. This is also the trust boundary
// for diagrams — everything is bounded and sanitized here (node/edge caps,
// deduped ids, truncated labels, dropped dangling edges, cycle-safe depths), so
// the Canvas2D presenter just draws what this returns. Bun-tested; the canvas
// drawing itself is not.

export const MAX_NODES = 32
export const MAX_LABEL = 24
const BOX_H = 30
const PAD = 40

const truncate = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s)

// Estimate a box width from the label without a canvas measure (positioning is
// pure; the presenter's real text is centered inside this box).
const boxWidth = (label) => Math.max(54, Math.min(220, label.length * 7.5 + 24))

function normalizeEdge(e) {
  if (Array.isArray(e)) return [e[0], e[1]]
  if (e && typeof e === "object") return [e.from, e.to]
  return [undefined, undefined]
}

// Longest-path depth per node, cycle-safe: relax edges up to |nodes| times and
// clamp so a cycle can't push a column off the screen.
function computeDepths(nodes, edges) {
  const depth = new Map(nodes.map((n) => [n.id, 0]))
  for (let iter = 0; iter < nodes.length; iter++) {
    let changed = false
    for (const {from, to} of edges) {
      const nd = depth.get(from) + 1
      if (nd > depth.get(to)) {
        depth.set(to, nd)
        changed = true
      }
    }
    if (!changed) break
  }
  const cap = Math.max(0, nodes.length - 1)
  for (const [id, d] of depth) depth.set(id, Math.min(d, cap))
  return depth
}

export function layoutGraph(spec, {width = 1024, height = 512} = {}) {
  // Sanitize nodes: cap count, require a stringable id, dedupe, truncate labels.
  const rawNodes = Array.isArray(spec && spec.nodes) ? spec.nodes : []
  const nodes = []
  const byId = new Map()
  for (const n of rawNodes) {
    if (nodes.length >= MAX_NODES) break
    const id = n != null && n.id != null ? String(n.id) : null
    if (id == null || byId.has(id)) continue
    const label = truncate(n.label != null ? String(n.label) : id, MAX_LABEL)
    const node = {id, label, w: boxWidth(label), h: BOX_H}
    byId.set(id, node)
    nodes.push(node)
  }

  // Sanitize edges: both endpoints must be known nodes.
  const rawEdges = Array.isArray(spec && spec.edges) ? spec.edges : []
  const edges = []
  for (const e of rawEdges) {
    const [f, t] = normalizeEdge(e)
    const from = f != null ? String(f) : null
    const to = t != null ? String(t) : null
    if (from == null || to == null || !byId.has(from) || !byId.has(to)) continue
    edges.push({from, to})
  }

  if (nodes.length === 0) return {width, height, nodes: [], edges: []}

  // Place: x by depth column, y evenly spaced within the column.
  const depth = computeDepths(nodes, edges)
  const colCount = Math.max(...nodes.map((n) => depth.get(n.id))) + 1
  const columns = new Map()
  for (const n of nodes) {
    const d = depth.get(n.id)
    if (!columns.has(d)) columns.set(d, [])
    columns.get(d).push(n)
  }

  const usableW = width - PAD * 2
  for (const [d, colNodes] of columns) {
    const cx = colCount === 1 ? width / 2 : PAD + (usableW * d) / (colCount - 1)
    colNodes.forEach((n, i) => {
      n.cx = cx
      n.cy = (height * (i + 1)) / (colNodes.length + 1)
    })
  }

  // Edges: from the source's right border to the target's left border (the
  // layout flows left→right by dependency).
  const positioned = edges.map(({from, to}) => {
    const a = byId.get(from)
    const b = byId.get(to)
    return {x1: a.cx + a.w / 2, y1: a.cy, x2: b.cx - b.w / 2, y2: b.cy}
  })

  return {width, height, nodes, edges: positioned}
}
