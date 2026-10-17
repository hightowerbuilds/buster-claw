import {escapeHtml} from "../lib/html.js"

// The tab strip's right-click menu: Rename for every tab; Swap sides and
// Separate for a /split tab; a "Join with" chip per joinable tab otherwise.
//
// Split out of tab_strip.js on 10-16 (CODE_QUALITY_SWEEP Phase 8), the same
// mixin shape as TabRename and TabLayout: it reads `this.load()`,
// `this.render()` and the split verbs the strip owns, and owns nothing but the
// menu element and its dismissal listeners. The layout reason it is a
// horizontal flyout pinned to the strip's band is in openMenu.
export const TabMenu = {
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
          `<button type="button" data-jointarget="${escapeHtml(t.path)}" ` +
          `class="${btn} max-w-[12rem] truncate">${escapeHtml(t.label)}</button>`
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
}
