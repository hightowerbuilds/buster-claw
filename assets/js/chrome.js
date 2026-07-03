// The embedded browser's chrome — tab strip + toolbar + bookmark bar. Loaded by
// /browser/chrome (BusterClawWeb.BrowserChromeController, which is now a thin
// HTML shell) into a `browser-chrome-<sid>` child webview. Bundled by esbuild as
// its own entry point → /assets/js/chrome.js.
//
// Ownership: this file owns the tab-strip UI and tab lifecycle; Rust
// (desktop/tauri/src/browser.rs) owns the content webviews and the per-surface
// active-tab pointer. `?sid=` (surfaced here via <body data-sid>) identifies the
// browser surface this chrome drives so side-by-side browsers stay independent.

import {resolve as resolveUrl, display as displayUrl, deriveLabel, faviconFor} from "./lib/browser_url.js"

const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke
const origin = window.location.origin
const homeUrl = origin + "/browser/home"

// The browser surface this chrome drives. Every browser_* invoke carries it
// (injected by inv() below).
const SID = document.body.dataset.sid || "main"
// Omnibox search engine (query appended); server-injected from the
// browser_search_url setting.
const SEARCH_URL = document.body.dataset.searchUrl || undefined

const addr = document.getElementById("addr")
const tabsEl = document.getElementById("tabs")
const barEl = document.getElementById("bookmarkbar")
const progressEl = document.getElementById("progress")

// Invoke a Tauri command, surfacing failures in the console (so a denied
// permission or a missing webview is visible rather than silent). Every
// browser_* command is surface-scoped, so inject surfaceId here.
function inv(cmd, args) {
  if (!invoke) return Promise.resolve()
  return invoke(cmd, Object.assign({surfaceId: SID}, args || {})).catch(function (e) {
    console.error("browser " + cmd + " failed:", e)
  })
}

const resolve = (raw) => resolveUrl(raw, origin, {searchUrl: SEARCH_URL})
const display = (u) => displayUrl(u, origin)

// --- tab state (chrome owns the strip; Rust owns the webviews) ---
// Each tab also tracks `loading` (spinner while a navigation is in flight)
// and `favicon` (host favicon, mirroring the bookmark-bar pattern).
let tabs = [{id: "1", url: "", label: "New tab", loading: false, favicon: null}]
let activeId = "1"
let nextId = 2

// --- session persistence (roadmap Phase 2.1) ---
// The model above lives in this webview's JS heap, so an app restart forgets
// every tab. Every mutation schedules a debounced POST of {tabs, active} to
// Phoenix (keyed by surface); restoreTabs() below hydrates on a cold load.
const INITIAL_VALUE = addr.value.trim()

function serializeTabs() {
  return {
    tabs: tabs.map((t) => ({url: t.url, label: t.label})),
    active: Math.max(0, tabs.findIndex((t) => t.id === activeId))
  }
}

let saveTimer
function scheduleSaveTabs() {
  clearTimeout(saveTimer)
  saveTimer = setTimeout(function () {
    fetch(origin + "/browser/tabs?sid=" + encodeURIComponent(SID), {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify(serializeTabs())
    }).catch(function () {})
  }, 500)
}

// Hydrate the strip from the saved state. Runs once at chrome boot — a fresh
// chrome means a fresh browser (Rust just created content tab "1"), so the
// saved tabs are recreated through the normal new-tab path. A deep link
// (?url=) owns tab 1 and the saved tabs append after it; otherwise tab 1 (the
// homepage Rust opened) is navigated to the first saved tab.
async function restoreTabs() {
  let saved
  try {
    const r = await fetch(origin + "/browser/tabs?sid=" + encodeURIComponent(SID), {
      headers: {accept: "application/json"}
    })
    if (!r.ok) return
    saved = await r.json()
  } catch (e) { return }

  const entries = (saved && Array.isArray(saved.tabs) ? saved.tabs : []).filter(
    (t) => t && typeof t.url === "string" && t.url !== "" && t.url !== homeUrl
  )
  if (!entries.length) return

  const deepLinked = INITIAL_VALUE !== ""
  const first = tabs[0]
  if (!deepLinked) {
    const e = entries[0]
    first.url = e.url
    first.label = e.label || deriveLabel(e.url, origin)
    first.favicon = faviconFor(e.url, origin)
    inv("browser_navigate", {tabId: first.id, url: e.url})
  }
  entries.slice(deepLinked ? 0 : 1).forEach((e) => {
    const id = String(nextId++)
    tabs.push({
      id,
      url: e.url,
      label: e.label || deriveLabel(e.url, origin),
      loading: false,
      favicon: faviconFor(e.url, origin)
    })
    inv("browser_new_tab", {tabId: id, url: e.url})
  })

  // Reactivate: the deep link keeps the front (it's what was asked for);
  // otherwise the saved active tab. Rust's active pointer moved with every
  // browser_new_tab above, so always re-sync it explicitly.
  const idx = Number.isInteger(saved.active) && saved.active >= 0 ? saved.active : 0
  const target = deepLinked ? first : tabs[Math.min(idx, tabs.length - 1)] || first
  activeId = target.id
  if (document.activeElement !== addr) addr.value = display(target.url)
  renderTabs()
  inv("browser_switch_tab", {tabId: target.id})
  scheduleSaveTabs()
}

// Reflect the active tab's loading state in the top progress bar.
function updateProgress() {
  const t = activeTab()
  progressEl.classList.toggle("on", !!(t && t.loading))
}

function renderTabs() {
  tabsEl.textContent = ""
  tabs.forEach((t) => {
    const tab = document.createElement("div")
    tab.className = "tab" + (t.id === activeId ? " active" : "")
    tab.title = t.label
    // Leading affordance: a spinner while loading, otherwise the favicon.
    if (t.loading) {
      const spin = document.createElement("span")
      spin.className = "spin"
      tab.appendChild(spin)
    } else if (t.favicon) {
      const fav = document.createElement("img")
      fav.className = "fav"
      fav.src = t.favicon; fav.alt = ""; fav.loading = "lazy"
      fav.onerror = () => fav.remove()
      tab.appendChild(fav)
    }
    const label = document.createElement("span")
    label.className = "label"
    label.textContent = t.label
    label.onclick = () => switchTab(t.id)
    const x = document.createElement("span")
    x.className = "x"
    x.textContent = "×"
    x.title = "Close tab"
    x.onclick = (e) => { e.stopPropagation(); closeTab(t.id) }
    tab.appendChild(label)
    tab.appendChild(x)
    tabsEl.appendChild(tab)
  })
  const add = document.createElement("button")
  add.id = "newtab"; add.type = "button"; add.title = "New tab"; add.textContent = "+"
  add.onclick = () => newTab()
  tabsEl.appendChild(add)
  updateProgress()
}

function activeTab() { return tabs.find((t) => t.id === activeId) }

// --- app-tab switcher (chrome-carried; see Phase 0.5 #2 in the roadmap) ---
// The native browser webviews render above the app's DOM, covering its tab
// strip — so the chrome carries its own: a Home chip plus every open app tab,
// read from the same localStorage the TabStrip hook persists ("bc:tabs"; the
// chrome shares the app's origin and WKWebView data store). Clicking a chip
// navigates the MAIN webview via Rust (browser_app_navigate); the surfaces
// hide-and-persist through the existing reconcile path.
const appTabsEl = document.getElementById("apptabs")

function loadAppTabs() {
  try { return JSON.parse(localStorage.getItem("bc:tabs")) || [] } catch (e) { return [] }
}

function renderAppTabs() {
  if (!appTabsEl) return
  appTabsEl.textContent = ""
  const chips = [{path: "/", label: "⌂ Home"}].concat(loadAppTabs())
  chips.forEach((t) => {
    if (!t || typeof t.path !== "string" || !t.path.startsWith("/")) return
    // The browser's own app tab is where we already are — show it as current.
    const base = t.path.split("?")[0]
    const isCurrent = base === "/browse" || (base === "/split" && t.path.includes("%2Fbrowse"))
    const el = document.createElement("button")
    el.type = "button"
    el.className = "atab" + (isCurrent ? " current" : "")
    el.title = isCurrent ? "You are here" : "Switch to " + (t.label || t.path)
    el.textContent = t.label || t.path
    if (!isCurrent) {
      el.onclick = () => inv("browser_app_navigate", {path: t.path})
    }
    appTabsEl.appendChild(el)
  })
}

// The tab list changes while we're hidden (tabs opened/closed elsewhere);
// re-read whenever this chrome regains focus or is re-shown, plus a slow tick.
window.addEventListener("focus", renderAppTabs)
setInterval(renderAppTabs, 10000)

// Native menu accelerators land here while a browser surface is shown — Rust
// (handle_menu_shortcut in browser.rs) evals into this chrome. Actions mirror
// the Tabs menu ids minus the bc_ prefix.
window.__menuShortcut = function (action) {
  if (action === "new_tab") return newTab()
  if (action === "close_tab") return closeTab(activeId)
  if (action === "reload") return inv("browser_reload", {tabId: activeId})
  if (action === "focus_address") { addr.focus(); addr.select(); return }
  if (action === "next_tab" || action === "prev_tab") {
    if (tabs.length < 2) return
    const i = tabs.findIndex((t) => t.id === activeId)
    const n = action === "next_tab" ? (i + 1) % tabs.length : (i - 1 + tabs.length) % tabs.length
    return switchTab(tabs[n].id)
  }
  const m = /^tab_([1-9])$/.exec(action)
  if (m) {
    // ⌘9 = last tab, matching the browser convention (and the app TabStrip).
    const n = Number(m[1])
    const t = n === 9 ? tabs[tabs.length - 1] : tabs[n - 1]
    if (t) switchTab(t.id)
  }
}

// --- bookmark bar (persistent quick-access strip below the toolbar) ---
function renderBookmarks(items) {
  barEl.textContent = ""
  if (!items || !items.length) {
    const hint = document.createElement("span")
    hint.className = "hint"
    hint.textContent = "Bookmarks you save appear here"
    barEl.appendChild(hint)
    return
  }
  items.forEach((b) => {
    const el = document.createElement("button")
    el.type = "button"
    el.className = "bmk"
    el.title = (b.folder ? b.folder + " / " : "") + (b.label || b.url) + "\n" + b.url
    if (b.favicon_url) {
      const img = document.createElement("img")
      img.src = b.favicon_url; img.alt = ""; img.loading = "lazy"
      el.appendChild(img)
    }
    const t = document.createElement("span")
    t.className = "t"
    t.textContent = b.label || b.url
    el.appendChild(t)
    el.onclick = () => inv("browser_navigate", {tabId: activeId, url: b.url})
    barEl.appendChild(el)
  })
}

function loadBookmarks() {
  fetch(origin + "/browser/bookmarks", {headers: {accept: "application/json"}})
    .then((r) => r.json())
    .then(renderBookmarks)
    .catch(function () {})
}

function newTab() {
  const id = String(nextId++)
  tabs.push({id, url: "", label: "New tab", loading: false, favicon: null})
  activeId = id
  addr.value = ""
  renderTabs()
  inv("browser_new_tab", {tabId: id, url: homeUrl})
  scheduleSaveTabs()
  addr.focus()
}

// Agent co-presence: open a new tab at `rawUrl` and make it active, routed
// through the chrome so the tab strip stays in sync. Called from Rust
// (browser_open_tab_active) via eval.
window.__agentOpenTab = function (rawUrl) {
  const url = resolve(rawUrl) || homeUrl
  const id = String(nextId++)
  tabs.push({id, url: "", label: "New tab"})
  activeId = id
  renderTabs()
  inv("browser_new_tab", {tabId: id, url})
  scheduleSaveTabs()
  if (document.activeElement !== addr) addr.value = display(url)
}

function switchTab(id) {
  if (id === activeId) return
  activeId = id
  const t = activeTab()
  if (t && document.activeElement !== addr) addr.value = display(t.url)
  renderTabs()
  inv("browser_switch_tab", {tabId: id})
  scheduleSaveTabs()
}

function closeTab(id) {
  inv("browser_close_tab", {tabId: id})
  const i = tabs.findIndex((t) => t.id === id)
  if (i < 0) return
  tabs.splice(i, 1)
  if (!tabs.length) { renderTabs(); newTab(); return }
  if (activeId === id) {
    const next = tabs[Math.max(0, i - 1)]
    activeId = next.id
    addr.value = display(next.url)
    inv("browser_switch_tab", {tabId: next.id})
  }
  renderTabs()
  scheduleSaveTabs()
}

// Called from Rust when a tab *starts* navigating (before the page loads):
// show the spinner and update the address bar/url optimistically. The real
// title arrives on completion via __onContentNavigated below.
window.__onContentLoading = function (id, u) {
  const t = tabs.find((x) => x.id === id)
  if (t) {
    t.url = u
    t.loading = true
    t.favicon = faviconFor(u, origin)
    t.label = deriveLabel(u, origin)
    // Safety net: some loads never report completion — network errors,
    // downloads, and blocked navigations don't fire on_page_load Finished,
    // so __onContentNavigated never clears the spinner. Drop it after a
    // grace period so it can't spin forever.
    clearTimeout(t.loadTimer)
    t.loadTimer = setTimeout(function () {
      const cur = tabs.find((x) => x.id === id)
      if (cur && cur.loading) { cur.loading = false; renderTabs() }
    }, 20000)
  }
  if (id === activeId && document.activeElement !== addr) addr.value = display(u)
  // New page → reset the bookmark button so a fresh save reads clearly.
  if (id === activeId) {
    const bm = document.getElementById("bookmark")
    if (bm) bm.textContent = "+ Bookmark"
  }
  renderTabs()
  scheduleSaveTabs()
}

// Called from Rust when a tab finishes loading, per tab id. `title` is the
// page's document.title (empty when unavailable); `favicon` is optional and
// falls back to a host-derived icon.
window.__onContentNavigated = function (id, u, title, favicon) {
  const t = tabs.find((x) => x.id === id)
  if (t) {
    clearTimeout(t.loadTimer)
    t.url = u
    t.loading = false
    t.favicon = favicon || faviconFor(u, origin)
    const named = (title || "").trim()
    t.label = named || deriveLabel(u, origin)
  }
  if (id === activeId && document.activeElement !== addr) addr.value = display(u)
  // New page → reset the bookmark button so a fresh save reads clearly.
  if (id === activeId) {
    const bm = document.getElementById("bookmark")
    if (bm) bm.textContent = "+ Bookmark"
  }
  renderTabs()
  scheduleSaveTabs()
  // History recording happens in Rust (record_history in browser.rs) on every
  // tab's page-load finish — the chrome is presentation only.
}

// --- downloads shelf (left cluster of the bottom row) ---
// Rust's on_download hook (browser.rs) drives these: a chip with a spinner
// while the file lands in ~/Downloads, then ✓ (click to reveal in Finder,
// resolved by id — never by a page-supplied path) or ✕ on failure. Finished
// chips fade out after 20s.
const downloadsEl = document.getElementById("downloads")
const downloads = [] // {id, name, state: "active" | "done" | "failed"}

function renderDownloads() {
  if (!downloadsEl) return
  downloadsEl.textContent = ""
  downloads.forEach((d) => {
    const el = document.createElement("button")
    el.type = "button"
    el.className = "dl " + d.state
    el.title = d.state === "done" ? "Reveal in Finder" : d.name
    if (d.state === "active") {
      const spin = document.createElement("span")
      spin.className = "spin"
      el.appendChild(spin)
    } else {
      const mark = document.createElement("span")
      mark.textContent = d.state === "done" ? "✓" : "✕"
      el.appendChild(mark)
    }
    const t = document.createElement("span")
    t.className = "t"
    t.textContent = d.name
    el.appendChild(t)
    if (d.state === "done") {
      el.onclick = () => inv("browser_reveal_download", {downloadId: d.id})
    }
    downloadsEl.appendChild(el)
  })
}

window.__onDownloadStarted = function (id, name) {
  downloads.unshift({id, name, state: "active"})
  // A download never fires page-load-finished, so the tab spinner would hang
  // for its full 20s safety net — clear it now that we know why it's spinning.
  const t = activeTab()
  if (t && t.loading) { clearTimeout(t.loadTimer); t.loading = false; renderTabs() }
  renderDownloads()
}

window.__onDownloadFinished = function (id, success) {
  const d = downloads.find((x) => x.id === id)
  if (d) d.state = success ? "done" : "failed"
  renderDownloads()
  setTimeout(function () {
    const i = downloads.findIndex((x) => x.id === id)
    if (i >= 0) { downloads.splice(i, 1); renderDownloads() }
  }, 20000)
}

function go() {
  const url = resolve(addr.value)
  if (url) inv("browser_navigate", {tabId: activeId, url})
}

// "/"-prefixed addresses browse the workspace in the active tab (debounced).
let browseTimer
addr.addEventListener("input", function () {
  if (!addr.value.startsWith("/")) return
  clearTimeout(browseTimer)
  browseTimer = setTimeout(function () {
    if (addr.value.startsWith("/")) {
      inv("browser_navigate", {
        tabId: activeId,
        url: origin + "/browser/workspace?q=" + encodeURIComponent(addr.value)
      })
    }
  }, 300)
})

function bookmark() {
  // Bookmark what the address bar actually shows for the active tab, resolved
  // back to a full URL. This stays correct even when a programmatic navigation
  // didn't fire the content-navigated callback — which would otherwise leave
  // activeTab().url stale and re-bookmark the previous page (so changing the
  // URL appeared to make no new bookmark).
  const t = activeTab()
  const url = resolve(addr.value) || (t && t.url)
  if (!url || url === homeUrl) return
  const label = (t && t.label && t.label !== "New tab" && t.label) || display(url) || url
  const btn = document.getElementById("bookmark")
  fetch(origin + "/browser/bookmarks?url=" + encodeURIComponent(url) +
        "&label=" + encodeURIComponent(label), {method: "POST"})
    .then(function () {
      btn.textContent = "Saved ✓"
      setTimeout(function () { btn.textContent = "+ Bookmark" }, 1500)
      loadBookmarks()
    })
    .catch(function () {})
}

document.getElementById("form").addEventListener("submit", function (e) { e.preventDefault(); go() })
document.getElementById("home").addEventListener("click", function () { inv("browser_navigate", {tabId: activeId, url: homeUrl}) })
document.getElementById("back").addEventListener("click", function () { inv("browser_back", {tabId: activeId}) })
document.getElementById("fwd").addEventListener("click", function () { inv("browser_forward", {tabId: activeId}) })
document.getElementById("reload").addEventListener("click", function () { inv("browser_reload", {tabId: activeId}) })
document.getElementById("bookmark").addEventListener("click", bookmark)

renderTabs()
renderAppTabs()
loadBookmarks()
restoreTabs()
addr.focus()
