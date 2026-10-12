import {labelForPath, tabDestination} from "./tabs.js"
import {recoverRetiredRoute} from "./retired_tabs.js"

export const basePath = path => String(path || "").split(/[?#]/)[0]
const paramsFor = path => new URL(path, "http://app.local").searchParams
const fail = message => { throw new Error(message) }
const local = path => typeof path === "string" && path.startsWith("/") && !path.startsWith("//") && !path.includes("\\")

export function browserSurface(path, fallback = "main") {
  const sid = paramsFor(path).get("surface")
  return sid && /^[A-Za-z0-9]{1,64}$/.test(sid) ? sid : fallback
}

export function splitPanes(tab, labels = {}) {
  const params = paramsFor(tab.path)
  return ["left", "right"].map((side, index) => {
    const path = recoverRetiredRoute(params.get(side))
    if (!local(path)) fail("This joined tab has an invalid pane.")
    const remembered = tab.panes?.[index]
    return {...remembered, path, label: remembered?.label || labelForPath(path, labels)}
  })
}

export function browserSurfaces(path) {
  if (basePath(path) === "/browse") return [browserSurface(path)]
  if (basePath(path) !== "/split") return []
  return splitPanes({path}).flatMap((pane, index) =>
    basePath(pane.path) === "/browse" ? [browserSurface(pane.path, index === 0 ? "left" : "right")] : [])
}

export function tabSnapshot(tabs, current) {
  const describe = tab => ({path: tab.path, label: tab.label, kind: basePath(tab.path) === "/split" ? "joined" : "tab"})
  return {current, tabs: tabs.map(tab => ({...describe(tab),
    ...(basePath(tab.path) === "/split" ? {panes: splitPanes(tab).map(describe)} : {})}))}
}

function matches(tab, selector, labels) {
  const text = selector.toLowerCase()
  const route = {browser: "/browse", chat: "/", home: "/"}[text] ||
    Object.keys(labels).find(path => labels[path].toLowerCase() === text) || (local(selector) ? selector : null)
  return tab.path === selector || tab.source_path === selector || tab.label?.toLowerCase() === text ||
    (route && basePath(tab.path) === route)
}

function resolve(tabs, selector, current, labels, joinable, create) {
  if (selector === "current") return tabs.find(tab => tab.path === current) || {path: current, label: labelForPath(current, labels)}
  const exact = tabs.find(tab => tab.path === selector)
  if (exact) return exact
  const found = tabs.filter(tab => matches(tab, selector, labels))
  if (found.length > 1) fail("Several tabs match. Use an exact path from app_tabs_list.")
  if (found.length === 1) return found[0]
  const joined = tabs.filter(tab => basePath(tab.path) === "/split" && splitPanes(tab, labels).some(pane => matches(pane, selector, labels)))
  if (joined.length) fail("That tab is already joined. Separate its joined tab first.")
  const route = {browser: "/browse", chat: "/", home: "/"}[selector.toLowerCase()] ||
    Object.keys(labels).find(path => labels[path].toLowerCase() === selector.toLowerCase()) || selector
  // New views use only named app routes. Query-bearing paths must already be
  // open, so arranging tabs cannot be used to navigate to an arbitrary URL.
  if (create && local(route) && joinable.includes(route)) return {path: route, label: labelForPath(route, labels)}
  fail("Tab not found. Use app_tabs_list to see the open tabs.")
}

function asPane(tab, options, used) {
  let path = tabDestination(tab)
  if (!local(path) || !options.joinable.includes(basePath(path))) fail("This view cannot be joined.")
  if (basePath(path) === "/browse") {
    const params = paramsFor(path)
    let sid = browserSurface(path)
    // Legacy solo tabs shared 'main'. Keep that live surface with its actual
    // owner; a second browser gets its own surface rather than stealing it.
    if (!params.has("surface") && options.browserOwner && options.browserOwner !== tab.path) {
      sid = `tab${crypto.randomUUID().replaceAll("-", "")}`
    }
    if (used.has(sid)) sid = `tab${crypto.randomUUID().replaceAll("-", "")}`
    used.add(sid)
    params.set("surface", sid)
    if (tab.url && !params.has("url")) params.set("url", tab.url)
    path = `/browse?${params}`
  }
  return {...tab, source_path: tab.source_path || tab.path, path, href: undefined}
}

function joinedTab(panes, label) {
  return {path: `/split?left=${encodeURIComponent(panes[0].path)}&right=${encodeURIComponent(panes[1].path)}`,
    label: label || panes.map(pane => pane.label).join(" | "), panes}
}

// Pure layout changes shared by the agent bridge and the manual tab controls.
// No tabs or native browser views are closed by join/separate/swap.
export function planTabLayout(action, args, tabs, current, options) {
  const {labels, joinable} = options
  const result = (next, path, changed = true) => ({tabs: next, path, changed})
  if (action === "join") {
    const selectors = [args.with || "current", args.tab]
    if (!selectors.every(value => typeof value === "string" && value.length)) fail("Choose two tabs to join.")
    const active = tabs.find(tab => tab.path === current)
    if (basePath(active?.path) === "/split") {
      const panes = splitPanes(active, labels)
      const already = selectors[0] === "current"
        ? panes.some(pane => matches(pane, selectors[1], labels))
        : panes.some(pane => matches(pane, selectors[0], labels)) && panes.some(pane => matches(pane, selectors[1], labels))
      if (already) return result(tabs, active.path, false)
    }
    const sources = selectors.map(selector => resolve(tabs, selector, current, labels, joinable, true))
    if (sources[0].path === sources[1].path) fail("Choose two different tabs to join.")
    const used = new Set()
    const panes = sources.map(tab => asPane(tab, options, used))
    const joined = joinedTab(panes)
    const next = tabs.filter(tab => !sources.some(source => source.path === tab.path))
    next.push(joined)
    return result(next, joined.path)
  }

  const source = resolve(tabs, args.tab || "current", current, labels, joinable, false)
  if (basePath(source.path) !== "/split") fail("That tab is not joined.")
  // Older splits did not carry surface IDs. Make the implicit left/right IDs
  // explicit before moving a browser out of its current position.
  const panes = splitPanes(source, labels).map((pane, index) => {
    if (basePath(pane.path) !== "/browse" || paramsFor(pane.path).has("surface")) return pane
    const params = paramsFor(pane.path)
    params.set("surface", index === 0 ? "left" : "right")
    return {...pane, path: `/browse?${params}`}
  })
  const next = tabs.filter(tab => tab.path !== source.path)
  if (action === "swap") {
    const swapped = joinedTab([...panes].reverse())
    next.push(swapped)
    return result(next, swapped.path)
  }
  const keep = action === "close-pane" ? [panes[args.side === "left" ? 1 : 0]] : panes
  if (!["separate", "close-pane"].includes(action)) fail("Unknown tab operation.")
  for (const pane of keep) {
    if (!next.some(tab => tab.path === pane.path)) next.push(pane)
  }
  const focus = keep.find(pane => basePath(pane.path) === "/") || keep[0]
  return result(next, focus.path)
}
