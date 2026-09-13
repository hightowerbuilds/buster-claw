// Tab-strip model: client-side persistence of open routes plus the path/label
// helpers shared by the TabStrip, SplitResizer, and TerminalView hooks.

// The Settings section presents several routes behind one in-page tab bar. In
// the top browser-style tab strip those routes collapse into a single "Settings"
// tab keyed by the group's canonical path, so traversing the sub-tabs only moves
// the in-page highlight — it never spawns new top-level tabs. The strip
// remembers the last sub-route visited (see the TabStrip hook's `sync`) so
// returning to the Settings tab reopens where you left off.
//
// This list MUST match `BusterClawWeb.SettingsTabs`'s tab paths exactly. A
// sub-tab missing here gets no group, so it opens its own top-level tab labelled
// with its raw path — which is precisely what /notify-settings did until it was
// added. `BusterClawWeb.SettingsTabsTest` fails the build if the two drift again.
const TAB_GROUPS = [
  {
    key: "/settings",
    paths: new Set([
      "/settings",
      "/appearance",
      "/notify-settings",
      "/integrations",
      "/security"
    ])
  }
]

// Canonical top-tab path for a route: the owning group's key if the route is in
// a collapsed group, else null.
export function canonicalGroupKey(path) {
  for (const g of TAB_GROUPS) if (g.paths.has(path)) return g.key
  return null
}

// A remembered Settings subpage can outlive its route (or leave Settings).
// Validate it against today's group before links and keyboard shortcuts use it.
export function tabDestination(tab) {
  if (!tab) return undefined
  const group = canonicalGroupKey(tab.path)
  if (group && tab.href) {
    const [path] = splitPathQuery(tab.href.split("#")[0])
    return canonicalGroupKey(path) === group ? tab.href : "/appearance"
  }
  return tab.href || tab.path
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

// ---- Closing a tab -----------------------------------------------------------
// One rule for every close button — the DOM strip's and the browser chrome's.
// (09-13-26: the chrome's row had no close buttons, and on /browse that row is
// the only tab strip you can reach, so a Browser tab could not be closed from
// the Browser tab.) Remove `path`; if it was on screen, the tab that slid into
// its slot takes over, else the one before it, else nothing — which means Home.
// `/duty` follows the shift, not the operator, so it never closes.
export function closeTabIn(tabs, path) {
  const list = Array.isArray(tabs) ? tabs : []
  const idx = path === "/duty" ? -1 : list.findIndex((t) => t && t.path === path)
  if (idx === -1) return {tabs: list, closed: false, next: null}
  const remaining = list.slice(0, idx).concat(list.slice(idx + 1))
  return {tabs: remaining, closed: true, next: remaining[idx] || remaining[idx - 1] || null}
}

// ---- The browser chrome's row of app tabs ----------------------------------
// The chrome is a separate webview and cannot read the main window's URL, so
// each browser surface records which app tab it is showing (`EmbeddedBrowser`
// writes it on mount) and the chrome reads it back to know which chip is "here".
const BROWSER_APP_TAB_KEY = "bc:browser-app-tab:"

export function rememberBrowserAppTab(sid, path) {
  try { localStorage.setItem(BROWSER_APP_TAB_KEY + sid, path) } catch (_e) { /* storage unavailable */ }
}

export function browserAppTab(sid) {
  try { return localStorage.getItem(BROWSER_APP_TAB_KEY + sid) } catch (_e) { return null }
}

// Chips for the chrome's row: Home first (the guaranteed way back), then every
// saved tab except a persisted "/" (which would be a second Home). `current` is
// the recorded app tab when there is one; with none — a surface opened before
// the recording existed — every browser tab counts as here, as it always did.
// `closable` mirrors the DOM strip minus two cases: Home is the way back, and a
// split you are inside is not closed from one pane's chrome, where a busy
// terminal in the other pane could not be asked about first.
export function chromeChips(savedTabs, currentPath) {
  const saved = (Array.isArray(savedTabs) ? savedTabs : []).filter(
    (t) => t && typeof t.path === "string" && t.path.startsWith("/") && t.path.split("?")[0] !== "/"
  )
  return [{path: "/", label: "Home"}].concat(saved).map((t) => {
    const base = t.path.split("?")[0]
    const current = currentPath
      ? t.path === currentPath
      : base === "/browse" || (base === "/split" && t.path.includes("%2Fbrowse"))
    const closable = base !== "/" && t.path !== "/duty" && !(current && base === "/split")
    return {...t, current, closable}
  })
}

// ---- Live terminal registry ------------------------------------------------
// Mounted TerminalView hooks register here so the TabStrip can ask, before a
// tab close, whether a terminal is running a foreground process (a build, a
// long command, or a live agent session) and would lose work if killed. Only
// the active route is mounted, so the registry only ever holds the terminal(s)
// of the tab being closed.
const liveTerminals = new Set()

export function registerTerminal(hook) {
  liveTerminals.add(hook)
}

export function unregisterTerminal(hook) {
  liveTerminals.delete(hook)
}

// True if any mounted terminal currently has a foreground child process. Each
// hook's isBusy() is best-effort (native fg-pgrp query); a throw counts as
// not-busy so a flaky probe can never block closing.
export async function anyTerminalBusy() {
  for (const hook of liveTerminals) {
    try {
      if (await hook.isBusy()) return true
    } catch (_e) {
      /* treat an unreadable terminal as idle */
    }
  }
  return false
}
