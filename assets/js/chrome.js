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
// Home/End caret handling for the URL bar and find input — WKWebView would
// otherwise insert a tofu glyph instead of moving the caret.
import {installCaretKeys} from "./lib/caret_keys.js"
import {renderAppTabChips} from "./lib/chrome_app_tabs.js"
import {loadTabs, shortcutDestination} from "./lib/tabs.js"
import {installBrowserNav} from "./lib/browser_nav.js"
import {createBar} from "./lib/chrome_bar.js"
import {createDownloads} from "./lib/chrome_downloads.js"

installCaretKeys()

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
const secureEl = document.getElementById("secure")

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
  // Ephemeral tabs are excluded: their non-persistent session dies with them,
  // so restoring the URL alone would silently change what the tab IS.
  const durable = tabs.filter((t) => !t.ephemeral)
  return {
    tabs: durable.map((t) => ({url: t.url, label: t.label})),
    active: Math.max(0, durable.findIndex((t) => t.id === activeId))
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
  inv("browser_switch_tab", {tabId: target.id, url: target.url})
  scheduleSaveTabs()
}

// Reflect the active tab's loading state in the top progress bar.
function updateProgress() {
  const t = activeTab()
  progressEl.classList.toggle("on", !!(t && t.loading))
}

let dragId = null // tab id being drag-reordered

function renderTabs() {
  renderAsk()
  tabsEl.textContent = ""
  tabs.forEach((t) => {
    const tab = document.createElement("div")
    tab.className =
      "tab" + (t.id === activeId ? " active" : "") + (t.ephemeral ? " eph" : "") +
      (t.suspended ? " suspended" : "")
    tab.title =
      t.label +
      (t.ephemeral ? " — ephemeral session (nothing persists)" : "") +
      (t.suspended ? " — suspended (reloads on click)" : "")
    // Drag to reorder (chrome-local: Rust doesn't care about strip order) and
    // middle-click to close — standard tab-strip ergonomics.
    tab.draggable = true
    tab.addEventListener("dragstart", (e) => {
      dragId = t.id
      e.dataTransfer.effectAllowed = "move"
    })
    tab.addEventListener("dragover", (e) => e.preventDefault())
    tab.addEventListener("drop", (e) => {
      e.preventDefault()
      if (!dragId || dragId === t.id) return
      const from = tabs.findIndex((x) => x.id === dragId)
      const to = tabs.findIndex((x) => x.id === t.id)
      dragId = null
      if (from < 0 || to < 0) return
      const [moved] = tabs.splice(from, 1)
      tabs.splice(to, 0, moved)
      renderTabs()
      scheduleSaveTabs()
    })
    tab.addEventListener("auxclick", (e) => {
      if (e.button === 1) { e.preventDefault(); closeTab(t.id) }
    })
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
  // New-tab buttons share one row under the (vertical) tab list.
  const newrow = document.createElement("div")
  newrow.className = "newrow"
  const add = document.createElement("button")
  add.id = "newtab"; add.type = "button"; add.title = "New tab"; add.textContent = "+"
  add.onclick = () => newTab(false)
  newrow.appendChild(add)
  // Private (ephemeral) tab — a human-facing entry to the same non-persistent
  // data store the agent's sandbox tabs use: no cookies/storage shared with the
  // normal session, nothing written to disk, excluded from session restore.
  const priv = document.createElement("button")
  priv.id = "newprivate"; priv.type = "button"; priv.textContent = "🕳"
  priv.title = "New private tab — ephemeral, nothing persists"
  priv.onclick = () => newTab(true)
  newrow.appendChild(priv)
  tabsEl.appendChild(newrow)
  updateProgress()
  updateSecurity(activeTab())
}

// Reflect the active tab's transport security in the padlock left of the address
// bar. Our own workspace pages (same origin) and blank tabs show nothing.
function updateSecurity(t) {
  const u = (t && t.url) || ""
  secureEl.classList.remove("https", "http")
  if (!u || u.indexOf(origin) === 0) { secureEl.textContent = ""; return }
  if (u.indexOf("https://") === 0) {
    secureEl.classList.add("https"); secureEl.textContent = "🔒"
    secureEl.title = "Secure — HTTPS"
  } else if (u.indexOf("http://") === 0) {
    secureEl.classList.add("http"); secureEl.textContent = "⚠"
    secureEl.title = "Not secure — HTTP (traffic can be read/modified in transit)"
  } else {
    secureEl.textContent = ""
  }
}

function activeTab() { return tabs.find((t) => t.id === activeId) }

// --- app-tab switcher (chrome-carried; see Phase 0.5 #2 in the roadmap) ---
// The native browser webviews render above the app's DOM, covering its tab
// strip — so the chrome carries its own row of app tabs, read from the same
// localStorage the TabStrip hook persists ("bc:tabs"; the chrome shares the
// app's origin and WKWebView data store), with the close buttons the covered
// strip would have had. The row lives in lib/chrome_app_tabs.js.
const appTabsEl = document.getElementById("apptabs")

function renderAppTabs() { renderAppTabChips(appTabsEl, SID, inv) }

// The tab list changes while we're hidden (tabs opened/closed elsewhere);
// re-read whenever this chrome regains focus or is re-shown, plus a slow tick.
window.addEventListener("focus", renderAppTabs)
setInterval(renderAppTabs, 10000)

// Native menu accelerators land here while a browser surface is shown — Rust
// (handle_menu_shortcut in browser.rs) evals into this chrome. Actions mirror
// the Tabs menu ids minus the bc_ prefix.
// Per-tab page zoom (⌘+/⌘−/⌘0 land here via the menu router). The factor
// lives here; Rust just applies it to the tab's webview.
const zoomLevels = {} // tab id -> factor

window.__menuShortcut = function (action) {
  if (action === "new_tab") return newTab()
  if (action === "close_tab") return closeTab(activeId)
  if (action === "toggle_sidebar") return toggleSidebar()
  if (action === "reload") return inv("browser_reload", {tabId: activeId})
  if (action === "focus_address") { addr.focus(); addr.select(); return }
  if (action === "find") return bar.openFindBar()
  if (action === "zoom_in" || action === "zoom_out" || action === "zoom_reset") {
    const cur = zoomLevels[activeId] || 1
    const next = action === "zoom_reset"
      ? 1
      : Math.min(5, Math.max(0.25, Math.round((cur + (action === "zoom_in" ? 0.1 : -0.1)) * 10) / 10))
    zoomLevels[activeId] = next
    return inv("browser_set_zoom", {tabId: activeId, factor: next})
  }
  if (action === "next_tab" || action === "prev_tab") {
    if (tabs.length < 2) return
    const i = tabs.findIndex((t) => t.id === activeId)
    const n = action === "next_tab" ? (i + 1) % tabs.length : (i - 1 + tabs.length) % tabs.length
    return switchTab(tabs[n].id)
  }
  // ⌘1 ⌘2 ⌘3 are the app's three places (work area, Settings, Browser), from
  // inside the Browser too — they never pick a browser tab.
  const m = /^tab_([1-3])$/.exec(action)
  if (m) inv("browser_app_navigate", {path: shortcutDestination(Number(m[1]), loadTabs())})
}

// --- the bookmark row: bookmarks / omnibox suggestions / find bar ---
// One strip, three modes, in lib/chrome_bar.js. The chrome hands it the
// address bar, the Tauri bridge and a way to ask which tab is active.
const bar = createBar({barEl, addr, inv, activeId: () => activeId, display, origin})

function newTab(priv) {
  const id = String(nextId++)
  tabs.push({
    id, url: "", label: priv ? "Private tab" : "New tab",
    loading: false, favicon: null, ephemeral: !!priv,
  })
  activeId = id
  addr.value = ""
  renderTabs()
  inv("browser_new_tab", {tabId: id, url: homeUrl, ephemeral: !!priv})
  scheduleSaveTabs()
  addr.focus()
}

// Agent co-presence indicator: a hazard-orange badge that appears whenever the
// agent reads or drives THIS tab (Rust pings `__agentActivity` at the top of
// every co-presence command) and auto-fades when it stops. Trust is the product
// — the user always sees when the agent has its hands on the live page.
;(function () {
  const style = document.createElement("style")
  style.textContent =
    "#agent-activity{position:fixed;top:6px;right:12px;z-index:2147483647;display:flex;" +
    "align-items:center;gap:6px;padding:3px 10px;border-radius:999px;" +
    "background:rgba(255,77,28,.14);border:1px solid #ff4d1c;color:#ff4d1c;" +
    "font:600 11px ui-monospace,Menlo,monospace;letter-spacing:.04em;white-space:nowrap;" +
    "opacity:0;transform:translateY(-5px);transition:opacity .18s,transform .18s;pointer-events:none}" +
    "#agent-activity.on{opacity:1;transform:translateY(0)}" +
    "#agent-activity .dot{width:7px;height:7px;border-radius:50%;background:#ff4d1c;" +
    "animation:agentPulse 1s ease-in-out infinite}" +
    "@keyframes agentPulse{0%,100%{opacity:1}50%{opacity:.25}}"
  document.head.appendChild(style)

  const badge = document.createElement("div")
  badge.id = "agent-activity"
  badge.setAttribute("aria-live", "polite")
  const dot = document.createElement("span")
  dot.className = "dot"
  const lbl = document.createElement("span")
  badge.appendChild(dot)
  badge.appendChild(lbl)
  document.body.appendChild(badge)

  let fadeTimer = null
  window.__agentActivity = function (action) {
    lbl.textContent = "Agent · " + (action || "working")
    badge.classList.add("on")
    clearTimeout(fadeTimer)
    fadeTimer = setTimeout(() => badge.classList.remove("on"), 1700)
  }
})()

// Agent co-presence: open a new tab at `rawUrl` and make it active, routed
// through the chrome so the tab strip stays in sync. Called from Rust
// (browser_open_tab_active) via eval.
window.__agentOpenTab = function (rawUrl, ephemeral) {
  const url = resolve(rawUrl) || homeUrl
  const id = String(nextId++)
  // Ephemeral (agent sandbox, Phase 3.4): non-persistent data store, dashed
  // tab, excluded from session restore — the session dies with the tab.
  tabs.push({id, url: "", label: "New tab", loading: false, favicon: null, ephemeral: !!ephemeral})
  activeId = id
  renderTabs()
  inv("browser_new_tab", {tabId: id, url, ephemeral: !!ephemeral})
  scheduleSaveTabs()
  if (document.activeElement !== addr) addr.value = display(url)
}

function switchTab(id) {
  if (id === activeId) return
  activeId = id
  const t = activeTab()
  if (t && document.activeElement !== addr) addr.value = display(t.url)
  // Pass the chip's saved URL so Rust can resurrect the tab if it was suspended
  // (background-tab eviction closed its webview while the chip lived on).
  renderTabs()
  inv("browser_switch_tab", {tabId: id, url: t ? t.url : ""})
  scheduleSaveTabs()
}

function closeTab(id) {
  inv("browser_close_tab", {tabId: id})
  delete zoomLevels[id] // don't leak a zoom entry per tab ever opened
  const i = tabs.findIndex((t) => t.id === id)
  if (i < 0) return
  tabs.splice(i, 1)
  if (!tabs.length) { renderTabs(); newTab(); return }
  if (activeId === id) {
    const next = tabs[Math.max(0, i - 1)]
    activeId = next.id
    addr.value = display(next.url)
    inv("browser_switch_tab", {tabId: next.id, url: next.url})
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
    t.suspended = false // it's live again the moment it starts loading
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

// Called from Rust when background-tab suspension evicts a tab's content
// webview (LRU beyond the live-tab budget). The chip lives on with its saved
// URL; we dim it so the user knows a click will reload. Cleared in
// __onContentLoading when the switch-back resurrects it.
window.__onTabSuspended = function (id) {
  const t = tabs.find((x) => x.id === id)
  if (t && !t.suspended) {
    t.suspended = true
    t.loading = false
    t.favicon = null
    renderTabs()
  }
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

// --- downloads shelf (left cluster of the bottom row; lib/chrome_downloads.js) ---
createDownloads({
  el: document.getElementById("downloads"),
  inv,
  // A download never fires page-load-finished, so the tab spinner would hang
  // for its full 20s safety net — clear it now that we know why it's spinning.
  onStarted() {
    const t = activeTab()
    if (t && t.loading) { clearTimeout(t.loadTimer); t.loading = false; renderTabs() }
  },
})

function go() {
  // Enter with a chip selected opens the suggestion; otherwise resolve as typed.
  const picked = bar.selectedSuggestion()
  if (picked) return bar.openSuggestion(picked)
  const url = resolve(addr.value)
  bar.clearSuggestions()
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
      bar.loadBookmarks()
    })
    .catch(function () {})
}

document.getElementById("form").addEventListener("submit", function (e) { e.preventDefault(); go() })
installBrowserNav(inv, () => activeId, origin, homeUrl, SID)
document.getElementById("bookmark").addEventListener("click", bookmark)

// --- "Ask about this page" (THREE_DOORS Phase 3) ---
// The one bridge this webview has into the app is browser_app_navigate, which
// loads a path in the main webview — so the active tab is handed over BY URL,
// and StatusLive stages a sentence in the composer. Staged, never sent: the
// operator still presses Enter (the same contract as Explained's Try in Chat).
// Hidden on a private/sandbox tab: reading a session that forgets everything
// is not what "this page" means to the person who opened it.
// The tab model's `label` IS the page title once a page has loaded (set from
// the navigation callback); before that it is "New tab", which no page has.
function renderAsk() {
  const t = activeTab()
  askBtn.hidden = !t || !t.url || !!t.ephemeral
}
const askBtn = document.getElementById("ask")
askBtn.addEventListener("click", function () {
  const t = activeTab()
  if (!t || !t.url || t.ephemeral) return
  const title = (t.label || "").slice(0, 200)
  const path = "/?ask=page&url=" + encodeURIComponent(t.url || "") + "&title=" + encodeURIComponent(title)
  inv("browser_app_navigate", {path: path})
})

// --- content blocking (WKContentRuleList shield) ---
// The block engine lives in Rust/WebKit; the chrome owns the on/off preference
// (persisted here) and reflects it in the shield. Toggling re-syncs Rust, which
// applies/clears the compiled rule list on every live tab (effect on next
// reload). Default ON.
const shieldEl = document.getElementById("shield")
let blocking = localStorage.getItem("bc:block") !== "0"
function renderShield() {
  shieldEl.classList.toggle("on", blocking)
  shieldEl.classList.toggle("off", !blocking)
  shieldEl.title = blocking
    ? "Content blocking on — ads & trackers blocked (click to disable; reload to apply)"
    : "Content blocking off (click to enable)"
}
function setBlocking(on) {
  blocking = on
  localStorage.setItem("bc:block", on ? "1" : "0")
  renderShield()
  inv("browser_set_content_blocking", {enabled: on})
}
shieldEl.addEventListener("click", function () { setBlocking(!blocking) })
renderShield()
// Rust's in-session default is ON; sync it to the persisted preference on load
// (matters when the user previously turned blocking off).
inv("browser_set_content_blocking", {enabled: blocking})

// --- tab sidebar collapse (bumper + ⌘B via the Tabs menu) ---
// The chrome owns the preference (persisted per surface); CSS repaints the
// sidebar, and Rust re-insets the content webviews to match (browser_set_sidebar).
const bumperEl = document.getElementById("bumper")
let sidebarCollapsed = localStorage.getItem("bc:sidebar:" + SID) === "1"
function renderSidebar() {
  document.body.classList.toggle("sidebar-collapsed", sidebarCollapsed)
  if (!bumperEl) return
  bumperEl.querySelector(".glyph").textContent = sidebarCollapsed ? "›" : "‹"
  bumperEl.title = (sidebarCollapsed ? "Show tabs" : "Hide tabs") + " (⌘B)"
  bumperEl.setAttribute("aria-expanded", String(!sidebarCollapsed))
}
function toggleSidebar() {
  sidebarCollapsed = !sidebarCollapsed
  localStorage.setItem("bc:sidebar:" + SID, sidebarCollapsed ? "1" : "0")
  renderSidebar()
  inv("browser_set_sidebar", {collapsed: sidebarCollapsed})
}
if (bumperEl) bumperEl.addEventListener("click", toggleSidebar)
renderSidebar()
// Rust's in-session default is expanded; sync the persisted preference on load
// (matters when the user previously collapsed the sidebar).
if (sidebarCollapsed) inv("browser_set_sidebar", {collapsed: true})

renderTabs()
renderAppTabs()
bar.loadBookmarks()
restoreTabs()
addr.focus()
