// Tab-strip model: client-side persistence of open routes plus the path/label
// helpers shared by the TabStrip, SplitResizer, and TerminalView hooks.
import {recoverRetiredRoute, recoverRetiredTabs} from "./retired_tabs.js"

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
  if (path === "/") return "/"
  for (const g of TAB_GROUPS) if (g.paths.has(path)) return g.key
  return null
}

// A remembered Settings subpage can outlive its route (or leave Settings).
// Validate it against today's group before links and keyboard shortcuts use it.
export function tabDestination(tab) {
  if (!tab) return undefined
  if (tab.path.split(/[?#]/)[0] === "/voice") return recoverRetiredRoute(tab.path)
  const group = canonicalGroupKey(tab.path)
  if (group && tab.href) {
    const href = recoverRetiredRoute(tab.href)
    const [path] = splitPathQuery(href.split("#")[0])
    return canonicalGroupKey(path) === group ? href : (group === "/" ? "/" : "/appearance")
  }
  return recoverRetiredRoute(tab.href || tab.path)
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
  try {
    const saved = JSON.parse(localStorage.getItem(TAB_STORAGE_KEY)) || []
    const tabs = recoverRetiredTabs(saved).map(tab =>
      tab.path === "/" && tab.label === "Home" ? {...tab, label: "Work area"} : tab
    )
    if (JSON.stringify(tabs) !== JSON.stringify(saved)) {
      try { saveTabs(tabs) } catch (_e) { /* Still recover when storage is full. */ }
    }
    return tabs
  } catch (_e) { return [] }
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

// ---- Work-area terminals ----------------------------------------------------
// ⌘T and the sidebar's Terminal button both come here (TERMINAL_PANELS D3/D5).
// On the work area the Workbench hook opens the next slot; anywhere else in the
// app we go to the work area and open one on arrival, with a one-shot flag the
// hook consumes — never a URL param, which a reload would replay. In the
// Browser the chord belongs to the chrome, so this does nothing there.
export const TERMINAL_NEW_FLAG = "bc:terminal-new"

export function terminalRequestRoute(pathname, onWorkArea) {
  if (String(pathname || "").split("?")[0] === "/browse") return "ignore"
  return onWorkArea ? "open" : "navigate"
}

// The native Tabs menu carries ⌘T too, and a menu accelerator can fire
// alongside the keydown handler (main.rs, on why ⌘W left the menu). One press
// must mean one terminal, so a second request inside 300ms is dropped.
let lastTerminalRequest = 0

export function requestNewTerminal(now = Date.now()) {
  if (now - lastTerminalRequest < 300) return "debounced"
  lastTerminalRequest = now
  const onWorkArea = Boolean(document.querySelector("#workbench-controller"))
  const route = terminalRequestRoute(window.location.pathname, onWorkArea)
  if (route === "open") window.dispatchEvent(new CustomEvent("bc:terminal-new"))
  if (route === "navigate") {
    try { sessionStorage.setItem(TERMINAL_NEW_FLAG, "1") } catch (_e) { /* the deep link still ensures one */ }
    window.location.href = "/?panel=terminal"
  }
  return route
}

export function takeTerminalNewFlag() {
  try {
    const set = sessionStorage.getItem(TERMINAL_NEW_FLAG) === "1"
    if (set) sessionStorage.removeItem(TERMINAL_NEW_FLAG)
    return set
  } catch (_e) { return false }
}

// ⌘1 ⌘2 ⌘3 — Work area, Settings, Browser. Fixed, and the only three
// (operator, 10-15). Settings reopens its remembered sub-page; Browser its
// first open browser tab; anything else is not a shortcut.
export function shortcutDestination(n, tabs) {
  const list = Array.isArray(tabs) ? tabs : []
  if (n === 1) return "/"
  if (n === 2) return tabDestination(list.find((t) => t && t.path === "/settings")) || "/appearance"
  if (n === 3) {
    const browser = list.find((t) => t && typeof t.path === "string" && t.path.split("?")[0] === "/browse")
    return browser ? browser.path : "/browse"
  }
  return null
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
const BROWSER_SURFACES_KEY = "bc:browser-surfaces"

export function knownBrowserSurfaces() {
  try {
    const saved = JSON.parse(localStorage.getItem(BROWSER_SURFACES_KEY))
    return [...new Set(["main", "left", "right", ...(Array.isArray(saved) ? saved : [])])]
      .filter(sid => typeof sid === "string" && /^[A-Za-z0-9]{1,64}$/.test(sid))
  } catch { return ["main", "left", "right"] }
}

export function rememberBrowserAppTab(sid, path) {
  try {
    localStorage.setItem(BROWSER_APP_TAB_KEY + sid, path)
    localStorage.setItem(BROWSER_SURFACES_KEY, JSON.stringify([...new Set([...knownBrowserSurfaces(), sid])]))
  } catch (_e) { /* storage unavailable */ }
}

export function browserAppTab(sid) {
  try { return recoverRetiredRoute(localStorage.getItem(BROWSER_APP_TAB_KEY + sid)) } catch (_e) { return null }
}

// Chips for the chrome's row: Work area first, then every saved tab except a
// persisted "/" (which would duplicate it). `current` is
// the recorded app tab when there is one; with none — a surface opened before
// the recording existed — every browser tab counts as here, as it always did.
// `closable` mirrors the DOM strip minus two cases: Work area is the way back, and a
// split you are inside is not closed from one pane's chrome, where a busy
// terminal in the other pane could not be asked about first.
export function chromeChips(savedTabs, currentPath) {
  const saved = (Array.isArray(savedTabs) ? savedTabs : []).filter(
    (t) => t && typeof t.path === "string" && t.path.startsWith("/") && t.path.split("?")[0] !== "/"
  )
  return [{path: "/", label: "Work area"}].concat(saved).map((t) => {
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

// The mounted terminal inside a container (a work-area pane), or null.
export function terminalHookIn(container) {
  for (const hook of liveTerminals) {
    if (container && hook.el && container.contains(hook.el)) return hook
  }
  return null
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
