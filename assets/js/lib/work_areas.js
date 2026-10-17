import {leavesOf, readLayout} from "./workbench.js"

export function areaIdForPath(path) {
  if (typeof path !== "string" || !path.startsWith("/") || path.startsWith("//")) return null
  try {
    const url = new URL(path, "http://app.local")
    if (url.pathname !== "/") return null
    const id = url.searchParams.get("area")
    return /^area-[1-9]\d{0,5}$/.test(id || "") ? id : "area-1"
  } catch { return null }
}

export function areaPath(id) { return !id || id === "area-1" ? "/" : `/?area=${encodeURIComponent(id)}` }
export function areaLabel(id) { return id === "area-1" ? "Work Area" : `Work Area ${id.slice(5)}` }
export function lastAreaPath() {
  try { return areaPath(readLayout(window.localStorage)?.active_area_id) } catch { return "/" }
}
export function terminalSessionKey(key) { return key === "terminal" ? "workbench" : key.replace(/^terminal-/, "workbench-") }

export function reconcileAreaTabs(tabs, state) {
  if (state?.version !== 2 || !Array.isArray(state.areas)) return tabs
  const areas = new Map(state.areas.map(area => [area.id, area]))
  const seen = new Set()
  // Joined areas already have a host. Do not reopen a duplicate solo tab.
  for (const tab of tabs) {
    if (!tab.path?.startsWith("/split?")) continue
    const params = new URL(tab.path, "http://app.local").searchParams
    for (const side of ["left", "right"]) {
      const id = areaIdForPath(params.get(side))
      if (id) seen.add(id)
    }
  }
  const next = tabs.flatMap(tab => {
    const id = areaIdForPath(tab.path)
    if (!id) return [tab]
    if (!areas.has(id) || seen.has(id)) return []
    seen.add(id)
    const legacy = ["Home", "Work area"].includes(tab.label)
    return [{...tab, path: areaPath(id), href: undefined, label: legacy ? areaLabel(id) : (tab.label || areaLabel(id))}]
  })
  for (const area of areas.values()) {
    if (!seen.has(area.id)) next.push({path: areaPath(area.id), label: areaLabel(area.id)})
  }
  return next
}

export function areaTerminalKeys(state, id) {
  const area = state?.areas?.find(area => area.id === id)
  return leavesOf(area?.tree).filter(key => key === "terminal" || key.startsWith("terminal-"))
}
