// Tab-strip model: client-side persistence of open routes plus the path/label
// helpers shared by the TabStrip, SplitResizer, and TerminalView hooks.

// The Settings section presents several routes behind one in-page tab bar
// (Appearance, GWS, Integrations, Configuration, Security). In the top
// browser-style tab strip those routes collapse into a single "Settings" tab
// keyed by the group's canonical path, so traversing the sub-tabs only moves the
// in-page highlight — it never spawns new top-level tabs.
const TAB_GROUPS = [
  {
    key: "/settings",
    paths: new Set(["/settings", "/appearance", "/gws", "/integrations", "/security", "/get-started", "/voice"])
  }
]

// Canonical top-tab path for a route: the owning group's key if the route is in
// a collapsed group, else null.
export function canonicalGroupKey(path) {
  for (const g of TAB_GROUPS) if (g.paths.has(path)) return g.key
  return null
}

const TAB_STORAGE_KEY = "bc:tabs"
export const SPLIT_RATIO_KEY = "bc:split-ratio"

function splitPathQuery(fullPath) {
  const value = String(fullPath || "")
  const idx = value.indexOf("?")
  if (idx === -1) return [value, ""]
  return [value.slice(0, idx), value.slice(idx + 1)]
}

export function loadTabs() {
  try { return JSON.parse(localStorage.getItem(TAB_STORAGE_KEY)) || [] } catch (_e) { return [] }
}

export function saveTabs(tabs) {
  localStorage.setItem(TAB_STORAGE_KEY, JSON.stringify(tabs))
}

function terminalLabelFromQuery(query, labels = {}) {
  const params = new URLSearchParams(query || "")
  return params.get("label") || labels["/terminal"] || "Terminal"
}

export function labelForPath(fullPath, labels = {}) {
  if (!fullPath) return "?"
  const [path, query] = splitPathQuery(fullPath)
  if (path === "/terminal") return terminalLabelFromQuery(query, labels)
  if (path === "/split") {
    const params = new URLSearchParams(query || "")
    return `${labelForPath(params.get("left"), labels)} | ${labelForPath(params.get("right"), labels)}`
  }
  return labels[path] || path
}

function newTerminalKey() {
  const stamp = new Date().toISOString().replace(/\D/g, "").slice(0, 14)
  const token = Math.random().toString(36).slice(2, 6)
  return `term-${stamp}-${token}`
}

function nextTerminalNumber(tabs, labels = {}) {
  const usedNumbers = tabs.flatMap((t) => {
    const [path] = splitPathQuery(t.path)
    if (path !== "/terminal") return []

    const match = String(t.label || labelForPath(t.path, labels)).match(/^Terminal(?:\s+(\d+))?$/)
    if (!match) return []

    return [match[1] ? parseInt(match[1], 10) : 1]
  })

  return Math.max(1, ...usedNumbers) + 1
}

function createTerminalTab(tabs = loadTabs(), labels = {}) {
  const key = newTerminalKey()
  const label = `Terminal ${nextTerminalNumber(tabs, labels)}`
  const path = `/terminal?session=${encodeURIComponent(key)}&label=${encodeURIComponent(label)}`
  return {path, label}
}

export function openNewTerminalTab(labels = {}) {
  const tabs = loadTabs()
  const tab = createTerminalTab(tabs, labels)
  tabs.push(tab)
  saveTabs(tabs)
  window.location.href = tab.path
}

function splitPathForTerminal(currentPath, side, labels = {}) {
  const other = createTerminalTab(loadTabs(), labels)
  const left = side === "left" ? other.path : currentPath
  const right = side === "left" ? currentPath : other.path
  return `/split?left=${encodeURIComponent(left)}&right=${encodeURIComponent(right)}`
}

export function openTerminalSplit(currentPath, side, labels = {}) {
  const splitPath = splitPathForTerminal(currentPath, side, labels)
  const currentTabPath = window.location.pathname + window.location.search
  const tabs = loadTabs().filter((t) => t.path !== currentPath && t.path !== currentTabPath)
  tabs.push({path: splitPath, label: labelForPath(splitPath, labels)})
  saveTabs(tabs)
  window.location.href = splitPath
}
