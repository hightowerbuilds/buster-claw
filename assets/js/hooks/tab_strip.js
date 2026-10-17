import {canonicalGroupKey, closeTabIn, loadTabs, saveTabs, labelForPath, requestNewTerminal, shortcutDestination, tabDestination} from "../lib/tabs.js"
import {escapeHtml} from "../lib/html.js"
import {TabWorkAreas} from "./tab_work_areas.js"
import {areaIdForPath} from "../lib/work_areas.js"
import {TabRename} from "./tab_rename.js"
import {dutyTabs} from "./duty_tab.js"
import {TabLayout} from "./tab_layout.js"
import {TabMenu} from "./tab_menu.js"
import {TabCloseConfirm} from "./tab_close_confirm.js"
import {recoverRetiredRoute} from "../lib/retired_tabs.js"

// Browser-style tab strip. Open routes are persisted client-side in
// localStorage so they survive LiveView navigations; the dock buttons open
// routes, and each open route shows up here as a tab with a close (×) button.
export const TabStrip = {
  ...TabRename,
  ...TabWorkAreas,
  ...TabLayout,
  ...TabMenu,
  ...TabCloseConfirm,
  mounted() {
    this.labels = this.parseLabels()
    this.el.addEventListener("click", (e) => this.onClick(e))
    // Drag one tab onto another to join them into a side-by-side split tab.
    this.el.addEventListener("dragstart", (e) => this.onDragStart(e))
    this.el.addEventListener("dragover", (e) => this.onDragOver(e))
    this.el.addEventListener("drop", (e) => this.onDrop(e))
    // Right-click a tab for the context menu (Join tabs, ...). WebKit (the
    // desktop app's WKWebView) does NOT fire `contextmenu` on draggable="true"
    // elements — which our tabs are, for drag-to-join — so drive the menu from
    // a right-button mousedown, which fires regardless. contextmenu stays as a
    // de-duped fallback for non-WebKit browsers (and to suppress the native menu).
    this.el.addEventListener("mousedown", (e) => this.onRightMouseDown(e))
    this.el.addEventListener("contextmenu", (e) => this.onContextMenu(e))
    // Double-click a tab to rename it; Enter/blur commits, Escape cancels.
    this.editingPath = null
    this.el.addEventListener("dblclick", (e) => this.onRenameStart(e))
    this.el.addEventListener("keydown", (e) => this.onRenameKeydown(e))
    this.el.addEventListener("focusout", (e) => this.onRenameBlur(e))
    this.onNav = () => {this.closeMenu(); this.sync(); this.render()}
    this.onDuty = () => {this.sync(); this.render()}
    window.addEventListener("bc:duty-changed", this.onDuty)
    // Re-render on every LiveView navigation so the active tab tracks the URL.
    window.addEventListener("phx:page-loading-stop", this.onNav)
    // BrowseLive pushes the loaded page's title/url so the tab reflects it.
    this.handleEvent("bc:tab_meta", (m) => this.onTabMeta(m))
    // Commands/CLI can request a visible in-app terminal tab.
    this.handleEvent("bc:open_terminal", (request) => this.onOpenTerminalRequest(request))
    // ⌘T opens a terminal tab; ⌘W only ever closes the active tab (never the
    // window — quitting is reserved for the native ⌘Q). Capture phase so we beat
    // xterm's own key handling.
    this.onKeydown = (e) => this.handleShortcut(e)
    window.addEventListener("keydown", this.onKeydown, true)
    // The joined-tab "swap sides" control (rendered in /split) asks us to swap,
    // so the persisted tab path + label stay in sync.
    this.onSwapSplit = () => this.swapSides(this.currentKey())
    window.addEventListener("bc:swap-split", this.onSwapSplit)
    // The per-pane close (×) in /split asks us to drop one side and keep the
    // other as a solo tab.
    this.onCloseSplitPane = (e) => this.closeSplitPane(e.detail && e.detail.side)
    window.addEventListener("bc:close-split-pane", this.onCloseSplitPane)
    // Native menu accelerators (Tabs menu) land here when no browser surface
    // is shown — Rust (handle_menu_shortcut in browser.rs) evals into the app
    // webview. The menu owns the bound keys regardless of focus, so this is
    // how ⌘T/⌘W/⌘1-9 keep driving app tabs outside the browser.
    window.__bcMenuShortcut = (action) => this.menuShortcut(action)
    this.setupWorkAreas()
    this.sync()
    this.render()
    // Heal any native browser surface left stuck by a prior full-page reload.
    this.reconcileBrowserSurfaces()
    this.setupTabCommands()
  },
  reconnected() { this.onTabsFocus() },
  destroyed() {
    window.removeEventListener("bc:workbench-state", this.onAreaState)
    window.removeEventListener("focus", this.onTabsFocus)
    window.removeEventListener("bc:duty-changed", this.onDuty)
    this.closeMenu()
    if (window.__bcMenuShortcut) delete window.__bcMenuShortcut
    window.removeEventListener("phx:page-loading-stop", this.onNav)
    window.removeEventListener("keydown", this.onKeydown, true)
    window.removeEventListener("bc:swap-split", this.onSwapSplit)
    window.removeEventListener("bc:close-split-pane", this.onCloseSplitPane)
  },
  // Menu-accelerator actions, mirroring handleShortcut's keydown behavior.
  menuShortcut(action) {
    if (action === "new_tab") return requestNewTerminal()
    if (action === "close_tab") return this.closeCurrentTab()
    if (action === "reload") return window.location.reload()
    if (action === "next_tab" || action === "prev_tab") {
      const tabs = this.load()
      if (tabs.length < 2) return
      const i = tabs.findIndex((t) => t.path === this.currentKey())
      const n = action === "next_tab" ? (i + 1) % tabs.length : (i - 1 + tabs.length) % tabs.length
      this.navigateTab(this.navTarget(tabs[n]))
      return
    }
    const m = /^tab_([1-3])$/.exec(action)
    if (m) this.jumpTo(Number(m[1]))
  },
  parseLabels() {
    try { return JSON.parse(this.el.dataset.labels || "{}") } catch (_e) { return {} }
  },
  load() {
    return dutyTabs(loadTabs(), document.getElementById("duty-tab-state")?.dataset.active === "true")
  },
  save(tabs) { saveTabs(tabs) },
  // Full paths distinguish browser tabs; Settings routes share one tab.
  currentKey() {
    const group = canonicalGroupKey(window.location.pathname + window.location.search)
    if (group) return group
    return recoverRetiredRoute(window.location.pathname + window.location.search)
  },
  labelFor(key) {
    return labelForPath(key, this.labels)
  },
  shortLabel(fullPath) {
    return labelForPath(fullPath, this.labels)
  },
  sync() {
    const key = this.currentKey()
    const tabs = this.load()
    // Drop legacy per-subroute tabs for any collapsed group; they fold into
    // the group's single canonical tab. Keep canonical and ungrouped tabs.
    const pruned = tabs.filter((t) => {
      const group = canonicalGroupKey(t.path)
      return !group || group === t.path
    })
    let changed = pruned.length !== tabs.length
    // For a collapsed group (e.g. Settings), remember the actual sub-route so
    // returning to the tab reopens where you left off — not the group's
    // canonical default. The tab stays keyed by the group path (one tab, one
    // highlight); `href` only steers navigation.
    const subRoute =
      window.location.pathname !== "/" && canonicalGroupKey(window.location.pathname + window.location.search) &&
      window.location.pathname + window.location.search
    const existing = pruned.find((t) => t.path === key)
    if (!existing) {
      const tab = {path: key, label: this.labelFor(key)}
      if (subRoute) tab.href = subRoute
      pruned.push(tab)
      changed = true
    } else if (subRoute && existing.href !== subRoute) {
      existing.href = subRoute
      changed = true
    }
    if (changed) this.save(pruned)
  },
  // Where a tab navigates when activated. Usually its own path; for a collapsed
  // group tab it's the remembered last sub-route (`href`), so Settings reopens
  // on the sub-tab you were last on rather than the canonical default.
  navTarget(tab) {
    return tabDestination(tab)
  },
  // A loaded page tells us its title/url; reflect both on the current tab so
  // it shows the page title (not "Browse") and can carry the url into a split.
  onTabMeta({title, url}) {
    const key = this.currentKey()
    const tabs = this.load()
    const tab = tabs.find((t) => t.path === key)
    if (!tab) return
    if (title) tab.label = title
    tab.url = url
    this.save(tabs)
    this.render()
  },
  onOpenTerminalRequest(request) {
    const path = request?.path
    if (!path) return

    const label = request.label || this.labelFor(path)
    const tabs = this.load().filter((t) => t.path !== path)
    tabs.push({
      path,
      label,
      role_key: request.role_key,
      agent_name: request.agent_name,
      purpose: request.purpose,
      startup_profile: request.startup_profile
    })
    this.save(tabs)

    if (request.activate === false) {
      this.render()
    } else {
      window.location.href = path
    }
  },
  render() {
    const active = this.currentKey()
    const tabs = this.load().map((t) => this.tabHtml(t, t.path === active)).join("")
    this.el.innerHTML = tabs
    if (this.editingPath) {
      const input = this.el.querySelector("[data-tab-edit]")
      if (input) input.focus()
    }
  },
  tabHtml(tab, isActive) {
    const wrap = isActive
      ? "group flex shrink-0 items-center gap-1 rounded-t-lg border border-b-0 border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium text-base-content"
      : "group flex shrink-0 items-center gap-1 rounded-t-lg border border-transparent bg-base-200 px-3 py-1.5 text-sm text-base-content/60 hover:bg-base-100/70 hover:text-base-content"
    const label = escapeHtml(tab.label)
    const path = escapeHtml(tab.path)
    // While renaming: the name is replaced by an empty focused input.
    if (tab.path === this.editingPath) {
      return `<span class="${wrap}" data-path="${path}">` +
        `<input data-tab-edit type="text" value="" aria-label="Rename tab" ` +
        `autocomplete="off" spellcheck="false" ` +
        `class="w-32 max-w-[12rem] bg-transparent text-sm outline-none" /></span>`
    }
    const href = escapeHtml(this.navTarget(tab))
    if (tab.path === "/duty") {
      return `<span class="${wrap} text-primary" data-path="/duty">` +
        `<span class="size-2 rounded-full bg-primary animate-pulse" aria-hidden="true"></span>` +
        `<a id="duty-tab" href="/duty" data-phx-link="redirect" data-phx-link-state="push">On duty</a></span>`
    }
    const area = areaIdForPath(tab.path)
    const linkType = area && window.location.pathname === "/" ? "patch" : "redirect"
    const close = area === "area-1" ? "" : `<button type="button" data-close="${path}" aria-label="Close ${label}" class="grid size-4 shrink-0 place-items-center rounded text-base-content/40 hover:bg-base-300 hover:text-base-content">&times;</button>`
    return `<span class="${wrap}" data-path="${path}" draggable="true">` +
      `<a href="${href}" draggable="false" data-phx-link="${linkType}" data-phx-link-state="push" class="max-w-[12rem] truncate">${label}</a>` +
      close + `</span>`
  },
  onClick(e) {
    const closeBtn = e.target.closest("[data-close]")
    if (!closeBtn) return
    e.preventDefault()
    e.stopPropagation()
    this.closeTab(closeBtn.getAttribute("data-close"))
  },
  onDragStart(e) {
    const tab = e.target.closest("[data-path]")
    this.dragPath = tab ? tab.getAttribute("data-path") : null
    if (this.dragPath && e.dataTransfer) e.dataTransfer.effectAllowed = "move"
  },
  onDragOver(e) {
    if (this.dragPath && e.target.closest("[data-path]")) e.preventDefault()
  },
  onDrop(e) {
    const tab = e.target.closest("[data-path]")
    if (!tab || !this.dragPath) return
    e.preventDefault()
    const targetPath = tab.getAttribute("data-path")
    // Default drag reorders; hold Alt to join two tabs into a split.
    if (e.altKey) {
      this.joinTabs(this.dragPath, targetPath)
    } else {
      this.reorderTab(this.dragPath, targetPath)
    }
    this.dragPath = null
  },
  // Move the dragged tab to the dropped target's position; persisted order is
  // the render order, so this survives navigations.
  reorderTab(from, to) {
    if (!from || !to || from === to) return
    const tabs = this.load()
    const fromIdx = tabs.findIndex((t) => t.path === from)
    const toIdx = tabs.findIndex((t) => t.path === to)
    if (fromIdx === -1 || toIdx === -1) return
    const [moved] = tabs.splice(fromIdx, 1)
    tabs.splice(toIdx, 0, moved)
    this.save(tabs)
    this.render()
  },
  async closeTab(path) {
    if (this.closeWorkArea(path)) return
    // Which tab goes and which takes the screen is shared with the browser
    // chrome's close buttons (`closeTabIn`), so the two strips cannot disagree.
    const {tabs, closed, next} = closeTabIn(this.load(), path)
    if (!closed) return
    // Only the active tab has a mounted terminal, so a busy terminal can only
    // belong to the current tab; closing a background tab never kills live work.
    if (path === this.currentKey() && !(await this.confirmCloseBusyTerminal())) return
    // Closing a tab that owns native browser webviews — a /browse tab, or a
    // /split holding a browser pane — must destroy them, else they linger
    // painted over whatever page we land on (the hook only *hides* on switch).
    const teardown = this.tearDownSplitBrowsers(path)
    this.save(tabs)
    if (path === this.currentKey()) {
      teardown.finally(() => (window.location.href = next ? this.navTarget(next) : "/"))
    } else {
      this.render()
    }
  },
  handleShortcut(e) {
    if (e.altKey || e.shiftKey || !(e.metaKey || e.ctrlKey)) return
    const key = (e.key || "").toLowerCase()
    // ⌘1 ⌘2 ⌘3 are the work area, Settings and the Browser — the only three.
    // ⌘T opens a terminal panel. ⌘W closes the active tab (never the window).
    if (!/^[123tw]$/.test(key)) return
    // Handle it ourselves and keep it from reaching the terminal / PTY.
    e.preventDefault()
    e.stopPropagation()
    if (key === "t") requestNewTerminal()
    else if (key === "w") this.closeCurrentTab()
    else this.jumpTo(Number(key))
  },
  // Activate the tab at a 1-indexed position in the visible (persisted) order.
  // 9 is special-cased to the last tab, matching browser tab shortcuts. No-op
  // when there's no tab at that slot.
  jumpTo(n) {
    const dest = shortcutDestination(n, this.load())
    if (dest) this.navigateTab(dest)
  },
  // ⌘W only ever closes the active tab. Closing the last remaining tab navigates
  // to "/" (which re-seeds the strip with a fresh home tab on the next page
  // load), so the window stays alive — quitting the app is reserved for the
  // native ⌘Q. The busy-terminal confirm lives in closeTab, so both the × click
  // and ⌘W are guarded.
  closeCurrentTab() {
    this.closeTab(this.currentKey())
  },
}
