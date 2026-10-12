const LABELS = {
  current: "Inspect page", navigate: "Navigate", open_tab: "Open tab", render: "Render page",
  read: "Read page", find_elements: "Find elements", click: "Click", fill: "Fill field",
  extract: "Extract", wait: "Wait", halt: "Stopped", handoff: "Human handoff",
  start: "Start run", start_run: "Start run", complete: "Complete", stop: "Stop run",
  take_wheel: "Take the wheel", resume: "Resume", capture: "Capture", screenshot: "Screenshot", cart: "Update cart",
}

export const actionLabel = action => LABELS[action] || String(action).replaceAll("_", " ")
export const failed = event => ["error", "halted", "stopped"].includes(event.outcome)
export const laneKey = event => event.source === "agent" ? `agent:${event.run_id}` : "shared"

export function pageLabel(url) {
  try {
    const page = new URL(url)
    return {host: page.host, path: page.pathname || "/"}
  } catch {
    return {host: "Browser session", path: "No page address recorded"}
  }
}

// Separate lanes never imply causality between independent runs. A return to
// an earlier page is a NEW visit, so loops remain readable in time order.
export function layoutActivity(events) {
  const lanes = new Map()
  for (const event of [...events].sort((a, b) => a.id - b.id)) {
    const key = laneKey(event)
    if (!lanes.has(key)) lanes.set(key, [])
    lanes.get(key).push(event)
  }
  const pages = [], nodes = [], edges = [], headings = []
  let top = 36, width = 440
  for (const [key, items] of lanes) {
    const visits = []
    for (const event of items) {
      let visit = visits.at(-1)
      if (!visit || visit.url !== event.url) {
        visit = {id: `page-${event.id}`, url: event.url, events: []}
        visits.push(visit)
      }
      visit.events.push(event)
    }
    headings.push({x: 32, y: top, text: key === "shared" ? "SHARED BROWSER" : `AGENT MODE · ${items[0].run_id}`})
    let previous = null, maxRows = 0
    visits.forEach((visit, column) => {
      const x = 32 + column * 238, y = top + 24
      pages.push({...visit, x, y, ...pageLabel(visit.url)})
      maxRows = Math.max(maxRows, visit.events.length)
      visit.events.forEach((event, row) => {
        const node = {id: `action-${event.id}`, x, y: y + 92 + row * 70, event}
        nodes.push(node)
        if (row === 0) edges.push({from: {x: x + 99, y: y + 64}, to: {x: x + 99, y: node.y}, kind: "page"})
        if (previous) {
          edges.push({from: {x: previous.x + 99, y: previous.y + 48}, to: {x: x + 99, y: node.y}, kind: "sequence"})
        }
        previous = node
      })
    })
    width = Math.max(width, visits.length * 238 + 32)
    top += 156 + maxRows * 70
  }
  return {pages, nodes, edges, headings, width, height: Math.max(top, 250)}
}

export function edgePath({from, to}) {
  if (from.x === to.x) return `M${from.x},${from.y} L${to.x},${to.y}`
  const bend = Math.max(from.y, to.y) + 26
  return `M${from.x},${from.y} C${from.x},${bend} ${to.x},${bend} ${to.x},${to.y}`
}

export function fitTransform(graph, width, height) {
  const scale = Math.min(1.15, Math.max(0.12, Math.min(width / graph.width, height / graph.height) * 0.9))
  return {scale, x: (width - graph.width * scale) / 2, y: (height - graph.height * scale) / 2}
}
