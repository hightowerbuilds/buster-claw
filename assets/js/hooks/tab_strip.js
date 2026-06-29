import {canonicalGroupKey, loadTabs, saveTabs, labelForPath, openNewTerminalTab, anyTerminalBusy} from "../lib/tabs.js"

// Browser-style tab strip. Open routes are persisted client-side in
// localStorage so they survive LiveView navigations; the dock buttons open
// routes, and each open route shows up here as a tab with a close (×) button.
export const TabStrip = {
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
    this.sync()
    this.render()
    // Heal any native browser surface left stuck by a prior full-page reload.
    this.reconcileBrowserSurfaces()
  },
  destroyed() {
    this.closeMenu()
    window.removeEventListener("phx:page-loading-stop", this.onNav)
    window.removeEventListener("keydown", this.onKeydown, true)
    window.removeEventListener("bc:swap-split", this.onSwapSplit)
    window.removeEventListener("bc:close-split-pane", this.onCloseSplitPane)
  },
  parseLabels() {
    try { return JSON.parse(this.el.dataset.labels || "{}") } catch (_e) { return {} }
  },
  load() { return loadTabs() },
  save(tabs) { saveTabs(tabs) },
  // Tab key is the full path incl. query, so multiple /browse tabs
  // (each /browse?t=<id>) are distinct, independent tabs. Any Settings
  // sub-route collapses to the single /settings key so they share one top tab.
  currentKey() {
    const group = canonicalGroupKey(window.location.pathname)
    if (group) return group
    return window.location.pathname + window.location.search
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
    if (!pruned.some((t) => t.path === key)) {
      pruned.push({path: key, label: this.labelFor(key)})
      changed = true
    }
    if (changed) this.save(pruned)
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
    const label = this.escape(tab.label)
    const path = this.escape(tab.path)
    // While renaming: the name is replaced by an empty focused input.
    if (tab.path === this.editingPath) {
      return `<span class="${wrap}" data-path="${path}">` +
        `<input data-tab-edit type="text" value="" aria-label="Rename tab" ` +
        `autocomplete="off" spellcheck="false" ` +
        `class="w-32 max-w-[12rem] bg-transparent text-sm outline-none" /></span>`
    }
    return `<span class="${wrap}" data-path="${path}" draggable="true">` +
      `<a href="${path}" draggable="false" data-phx-link="redirect" data-phx-link-state="push" class="max-w-[12rem] truncate">${label}</a>` +
      `<button type="button" data-close="${path}" aria-label="Close ${label}" ` +
      `class="grid size-4 shrink-0 place-items-center rounded text-base-content/40 hover:bg-base-300 hover:text-base-content">&times;</button>` +
      `</span>`
  },
  // ----- Double-click rename -----
  onRenameStart(e) {
    const tab = e.target.closest("[data-path]")
    if (!tab) return
    e.preventDefault()
    this.editingPath = tab.getAttribute("data-path")
    this.render()
  },
  onRenameKeydown(e) {
    if (!e.target.closest("[data-tab-edit]")) return
    if (e.key === "Enter") {
      e.preventDefault()
      this.commitRename(e.target.value)
    } else if (e.key === "Escape") {
      e.preventDefault()
      this.cancelRename()
    }
  },
  onRenameBlur(e) {
    const input = e.target.closest("[data-tab-edit]")
    if (input) this.commitRename(input.value)
  },
  commitRename(value) {
    if (!this.editingPath) return
    const path = this.editingPath
    this.editingPath = null
    const name = String(value || "").trim()
    if (name) {
      const tabs = this.load()
      const tab = tabs.find((t) => t.path === path)
      if (tab) {
        tab.label = name
        this.save(tabs)
      }
    }
    this.render()
  },
  cancelRename() {
    this.editingPath = null
    this.render()
  },
  onClick(e) {
    const newTab = e.target.closest("[data-newtab]")
    if (newTab) {
      e.preventDefault()
      this.openBrowserTab()
      return
    }
    const newTerminal = e.target.closest("[data-newterminal]")
    if (newTerminal) {
      e.preventDefault()
      this.openTerminalTab()
      return
    }
    const closeBtn = e.target.closest("[data-close]")
    if (!closeBtn) return
    e.preventDefault()
    e.stopPropagation()
    this.closeTab(closeBtn.getAttribute("data-close"))
  },
  openBrowserTab() {
    const token = Math.random().toString(36).slice(2, 8)
    window.location.href = `/browse?t=${token}`
  },
  openTerminalTab() {
    openNewTerminalTab(this.labels)
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
  // A pane carries its browsed page as ?url=<page> so the split can load it.
  paneParam(tabPath) {
    const tab = this.load().find((t) => t.path === tabPath)
    if (tab && tab.url) {
      return tabPath.split("?")[0] + "?url=" + encodeURIComponent(tab.url)
    }
    return tabPath
  },
  joinTabs(a, b) {
    // Don't join a tab to itself or nest splits inside splits.
    if (!a || !b || a === b) return
    if (a.split("?")[0] === "/split" || b.split("?")[0] === "/split") return
    const left = this.paneParam(a)
    const right = this.paneParam(b)
    // The two source tabs now live inside the joined tab — drop them.
    this.save(this.load().filter((t) => t.path !== a && t.path !== b))
    const dest = `/split?left=${encodeURIComponent(left)}&right=${encodeURIComponent(right)}`
    // Close a pre-existing solo browser surface so it can't linger over the
    // split; the pane reopens it fresh on its side.
    this.tearDownSplitBrowsers(a, b).finally(() => (window.location.href = dest))
  },
  // Swap the two sides of a joined tab.
  swapSides(splitPath) {
    const params = new URLSearchParams(splitPath.split("?")[1] || "")
    const left = params.get("left")
    const right = params.get("right")
    if (!left || !right) return
    const newPath = `/split?left=${encodeURIComponent(right)}&right=${encodeURIComponent(left)}`
    this.save(
      this.load().map((t) =>
        t.path === splitPath ? {path: newPath, label: this.labelFor(newPath)} : t
      )
    )
    // A browser's surface id is its side, so swapping moves it across; close the
    // old surface first or it stays painted on the side it was on.
    this.tearDownSplitBrowsers(left, right).finally(() => (window.location.href = newPath))
  },
  // Close one pane of a joined tab; the other side stays open as a solo tab.
  closeSplitPane(side) {
    const cur = this.currentKey()
    if (cur.split("?")[0] !== "/split") return
    const params = new URLSearchParams(cur.split("?")[1] || "")
    const keep = side === "left" ? params.get("right") : params.get("left")
    if (!keep) return
    const tabs = this.load().filter((t) => t.path !== cur)
    if (!tabs.some((t) => t.path === keep)) {
      tabs.push({path: keep, label: this.labelFor(keep)})
    }
    this.save(tabs)
    this.tearDownSplitBrowsers(params.get("left"), params.get("right")).finally(
      () => (window.location.href = keep)
    )
  },
  // Split a joined tab back into its two component tabs.
  separateTabs(splitPath) {
    const params = new URLSearchParams(splitPath.split("?")[1] || "")
    const left = params.get("left")
    const right = params.get("right")
    if (!left || !right) return
    const tabs = this.load().filter((t) => t.path !== splitPath)
    for (const p of [left, right]) {
      if (!tabs.some((t) => t.path === p)) tabs.push({path: p, label: this.labelFor(p)})
    }
    this.save(tabs)
    this.tearDownSplitBrowsers(left, right).finally(() => (window.location.href = left))
  },
  // Close every native browser surface if any of the given pane paths is a
  // browser. Native webviews are owned by Rust and survive the full-page reload
  // our split navigations do, so a stale surface stays pinned to its old box
  // (wrong side / "stuck") unless we close it first. Returns a promise so the
  // caller can wait for the close before the reload reopens a fresh surface on
  // the correct side — otherwise the close can race ahead and kill the new one.
  tearDownSplitBrowsers(...panePaths) {
    if (!panePaths.some((p) => (p || "").split("?")[0] === "/browse")) return Promise.resolve()
    const invoke = window.__TAURI__?.core?.invoke
    if (!invoke) return Promise.resolve()
    return invoke("browser_close").catch(() => {})
  },
  // Reconcile native browser surfaces against the current route on a fresh page
  // load. Surfaces are owned by the Rust shell and survive the full-page reload
  // our window.location.href navigations do; on such a reload the EmbeddedBrowser
  // hook's destroyed() (which hides its surface) doesn't fire, so a surface can
  // be left stuck on top of the next page. The route says which are valid —
  // "main" on /browse, "left"/"right" on /split, none anywhere else — so close
  // the rest. Closing an absent or about-to-be-reopened surface is a safe no-op
  // (each pane's hook opens its own id, never one we close here).
  reconcileBrowserSurfaces() {
    const invoke = window.__TAURI__?.core?.invoke
    if (!invoke) return
    const base = window.location.pathname
    const stale =
      base === "/browse" ? ["left", "right"] : base === "/split" ? ["main"] : ["main", "left", "right"]
    for (const sid of stale) invoke("browser_close", {surfaceId: sid}).catch(() => {})
  },
  // ----- Right-click context menu -----
  // Primary trigger in WebKit: right-button mousedown fires even on draggable
  // tabs, where `contextmenu` does not.
  onRightMouseDown(e) {
    if (e.button !== 2) return
    const tab = e.target.closest("[data-path]")
    if (!tab) return
    e.preventDefault()
    this.menuViaMouseDown = true
    this.openMenu(tab.getAttribute("data-path"), e.clientX, e.clientY)
  },
  onContextMenu(e) {
    const tab = e.target.closest("[data-path]")
    if (!tab) return
    // Always suppress the native menu over a tab.
    e.preventDefault()
    // mousedown already opened it (WebKit path) — don't reopen on the
    // contextmenu that may follow in other browsers.
    if (this.menuViaMouseDown) {
      this.menuViaMouseDown = false
      return
    }
    this.openMenu(tab.getAttribute("data-path"), e.clientX, e.clientY)
  },
  openMenu(path, x, _y) {
    this.closeMenu()
    this.menuPath = path
    const menu = document.createElement("div")
    // A horizontal flyout that lives in the tab-strip band and unfurls to the
    // right. The native browser webview is painted over the page area BELOW the
    // strip and always sits above HTML, so a normal dropdown falling into that
    // area gets clipped behind it. Staying inside the strip's own vertical band
    // keeps the menu fully visible. It scrolls horizontally if it overflows.
    menu.className =
      "fixed z-50 flex items-stretch gap-1 overflow-x-auto rounded-md border " +
      "border-base-300 bg-base-100 px-1 text-sm shadow-lg"
    menu.addEventListener("click", (e) => this.onMenuClick(e))
    menu.addEventListener("contextmenu", (e) => e.preventDefault())
    document.body.appendChild(menu)
    this.menuEl = menu
    this.renderMenu()

    // Pin to the tab strip's band; start at the clicked tab's right edge (so the
    // tab stays visible) and unfurl rightward, clamped to the viewport width.
    const strip = this.el.getBoundingClientRect()
    const sel = window.CSS && CSS.escape ? CSS.escape(path) : path
    const tabEl = this.el.querySelector(`[data-path="${sel}"]`)
    const anchorLeft = tabEl ? tabEl.getBoundingClientRect().right + 4 : x
    const left = Math.max(8, Math.min(anchorLeft, window.innerWidth - 120))
    menu.style.top = `${strip.top}px`
    menu.style.height = `${strip.height}px`
    menu.style.left = `${left}px`
    menu.style.maxWidth = `${Math.max(120, window.innerWidth - left - 8)}px`

    // Dismiss on outside click / Escape (deferred so the opening event doesn't close it).
    this.onDocClick = (ev) => {
      if (this.menuEl && !this.menuEl.contains(ev.target)) this.closeMenu()
    }
    this.onMenuKey = (ev) => {
      if (ev.key === "Escape") this.closeMenu()
    }
    setTimeout(() => {
      document.addEventListener("click", this.onDocClick)
      document.addEventListener("keydown", this.onMenuKey)
    }, 0)
  },
  // One horizontal row of actions. A /split tab gets Swap/Separate; any other
  // tab gets a "Join with" label followed by a chip per joinable tab — flat, no
  // submenu, since the bar has room to the right.
  renderMenu() {
    const isSplit = (this.menuPath || "").split("?")[0] === "/split"
    const btn =
      "flex shrink-0 items-center rounded px-3 whitespace-nowrap hover:bg-base-200"
    const lbl =
      "flex shrink-0 items-center px-2 text-xs font-semibold uppercase " +
      "tracking-wide text-base-content/50 whitespace-nowrap"
    // Rename is offered for every tab, joined or not.
    const rename = `<button type="button" data-menu="rename" class="${btn}">Rename</button>`
    if (isSplit) {
      this.menuEl.innerHTML =
        rename +
        `<button type="button" data-menu="swap" class="${btn}">Swap sides</button>` +
        `<button type="button" data-menu="separate" class="${btn}">Separate tabs</button>`
      return
    }
    const candidates = this.load().filter(
      (t) => t.path !== this.menuPath && !t.path.startsWith("/split")
    )
    if (candidates.length === 0) {
      this.menuEl.innerHTML = rename + `<span class="${lbl}">No other tabs to join</span>`
      return
    }
    const chips = candidates
      .map(
        (t) =>
          `<button type="button" data-jointarget="${this.escape(t.path)}" ` +
          `class="${btn} max-w-[12rem] truncate">${this.escape(t.label)}</button>`
      )
      .join("")
    this.menuEl.innerHTML = rename + `<span class="${lbl}">Join with</span>` + chips
  },
  onMenuClick(e) {
    const rename = e.target.closest("[data-menu='rename']")
    if (rename) {
      e.stopPropagation()
      const source = this.menuPath
      this.closeMenu()
      // Reuse the existing inline-edit path: render() focuses the input, and
      // Enter/blur commits through commitRename → saveTabs.
      this.editingPath = source
      this.render()
      return
    }
    const swap = e.target.closest("[data-menu='swap']")
    if (swap) {
      e.stopPropagation()
      const source = this.menuPath
      this.closeMenu()
      this.swapSides(source)
      return
    }
    const separate = e.target.closest("[data-menu='separate']")
    if (separate) {
      e.stopPropagation()
      const source = this.menuPath
      this.closeMenu()
      this.separateTabs(source)
      return
    }
    const target = e.target.closest("[data-jointarget]")
    if (target) {
      e.stopPropagation()
      const source = this.menuPath
      this.closeMenu()
      this.joinTabs(source, target.getAttribute("data-jointarget"))
    }
  },
  closeMenu() {
    if (this.onDocClick) {
      document.removeEventListener("click", this.onDocClick)
      this.onDocClick = null
    }
    if (this.onMenuKey) {
      document.removeEventListener("keydown", this.onMenuKey)
      this.onMenuKey = null
    }
    if (this.menuEl) {
      this.menuEl.remove()
      this.menuEl = null
    }
    this.menuPath = null
  },
  async closeTab(path) {
    const tabs = this.load()
    const idx = tabs.findIndex((t) => t.path === path)
    if (idx === -1) return
    // Only the active tab has a mounted terminal, so a busy terminal can only
    // belong to the current tab; closing a background tab never kills live work.
    if (path === this.currentKey() && !(await this.confirmCloseBusyTerminal())) return
    // Closing a tab that owns native browser webviews — a /browse tab, or a
    // /split holding a browser pane — must destroy them, else they linger
    // painted over whatever page we land on (the hook only *hides* on switch).
    const base = path.split("?")[0]
    let teardown = Promise.resolve()
    if (base === "/browse") {
      teardown = this.tearDownSplitBrowsers("/browse")
    } else if (base === "/split") {
      const params = new URLSearchParams(path.split("?")[1] || "")
      teardown = this.tearDownSplitBrowsers(params.get("left"), params.get("right"))
    }
    tabs.splice(idx, 1)
    this.save(tabs)
    if (path === this.currentKey()) {
      const next = tabs[idx] || tabs[idx - 1]
      teardown.finally(() => (window.location.href = next ? next.path : "/"))
    } else {
      this.render()
    }
  },
  handleShortcut(e) {
    if (e.altKey || e.shiftKey || !(e.metaKey || e.ctrlKey)) return
    const key = (e.key || "").toLowerCase()
    if (key !== "t" && key !== "w") return
    // Handle it ourselves and keep it from reaching the terminal / PTY.
    e.preventDefault()
    e.stopPropagation()
    if (key === "t") this.openTerminalTab()
    else this.closeCurrentTab()
  },
  // ⌘W only ever closes the active tab. Closing the last remaining tab navigates
  // to "/" (which re-seeds the strip with a fresh home tab on the next page
  // load), so the window stays alive — quitting the app is reserved for the
  // native ⌘Q. The busy-terminal confirm lives in closeTab, so both the × click
  // and ⌘W are guarded.
  closeCurrentTab() {
    this.closeTab(this.currentKey())
  },
  // Resolve true to proceed with a close, false to abort. When the active tab's
  // terminal is running a foreground process, ask first; idle terminals and
  // non-terminal tabs resolve true immediately (no prompt).
  async confirmCloseBusyTerminal() {
    if (!(await anyTerminalBusy())) return true
    return this.showCloseConfirm()
  },
  // Minimal Industrial Claw confirm modal (brutalist 2px borders, app color
  // tokens). Resolves true on Close, false on Cancel / Escape / backdrop click.
  showCloseConfirm() {
    return new Promise((resolve) => {
      const overlay = document.createElement("div")
      overlay.className = "fixed inset-0 z-[100] grid place-items-center bg-black/50"
      overlay.innerHTML =
        `<div role="dialog" aria-modal="true" ` +
        `class="w-80 max-w-[90vw] border-2 border-base-content bg-base-100 p-5 text-base-content shadow-lg">` +
        `<p class="text-sm">This terminal is running something. Close it anyway?</p>` +
        `<div class="mt-5 flex justify-end gap-2">` +
        `<button type="button" data-confirm-cancel ` +
        `class="border-2 border-base-content px-3 py-1 text-sm font-medium hover:bg-base-200">Cancel</button>` +
        `<button type="button" data-confirm-close ` +
        `class="border-2 border-primary bg-primary px-3 py-1 text-sm font-medium text-primary-content hover:opacity-90">Close</button>` +
        `</div></div>`

      const finish = (result) => {
        document.removeEventListener("keydown", onKey, true)
        overlay.remove()
        resolve(result)
      }
      const onKey = (e) => {
        if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); finish(false) }
        else if (e.key === "Enter") { e.preventDefault(); e.stopPropagation(); finish(true) }
      }
      overlay.addEventListener("click", (e) => {
        if (e.target === overlay || e.target.closest("[data-confirm-cancel]")) finish(false)
        else if (e.target.closest("[data-confirm-close]")) finish(true)
      })
      document.addEventListener("keydown", onKey, true)
      document.body.appendChild(overlay)
      overlay.querySelector("[data-confirm-close]")?.focus()
    })
  },
  // Defined for completeness but intentionally unreachable from the ⌘W path:
  // ⌘W must never quit the app (see closeCurrentTab).
  closeWindow() {
    try {
      const appWindow = window.__TAURI__?.window?.getCurrentWindow?.()
      if (appWindow) {
        appWindow.close()
        return
      }
    } catch (_e) {
      /* not in the desktop shell — fall through */
    }
    window.close()
  },
  escape(s) {
    return String(s).replace(/[&<>"']/g, (c) =>
      ({"&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;"}[c]))
  }
}
