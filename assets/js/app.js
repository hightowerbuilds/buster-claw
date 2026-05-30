// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/buster_claw"
import topbar from "../vendor/topbar"
import {Terminal as XTerm} from "@xterm/xterm"
import {FitAddon} from "@xterm/addon-fit"

const Hooks = {
  CalendarDrag: {
    mounted() {
      let draggingId = null
      let lastTarget = null

      this.el.addEventListener("dragstart", (e) => {
        const chip = e.target.closest("[data-event-id]")
        if (!chip) return
        draggingId = chip.dataset.eventId
        e.dataTransfer.effectAllowed = "move"
        // some browsers need this for the drag to fire
        e.dataTransfer.setData("text/plain", draggingId)
        chip.classList.add("opacity-50")
      })

      this.el.addEventListener("dragend", (e) => {
        const chip = e.target.closest("[data-event-id]")
        if (chip) chip.classList.remove("opacity-50")
        if (lastTarget) {
          lastTarget.classList.remove("ring-2", "ring-base-content")
          lastTarget = null
        }
        draggingId = null
      })

      this.el.addEventListener("dragover", (e) => {
        const cell = e.target.closest("[data-drop-date]")
        if (!cell) return
        e.preventDefault()
        e.dataTransfer.dropEffect = "move"
        if (lastTarget !== cell) {
          if (lastTarget) lastTarget.classList.remove("ring-2", "ring-base-content")
          cell.classList.add("ring-2", "ring-base-content")
          lastTarget = cell
        }
      })

      this.el.addEventListener("dragleave", (e) => {
        const cell = e.target.closest("[data-drop-date]")
        if (cell && cell === lastTarget && !cell.contains(e.relatedTarget)) {
          cell.classList.remove("ring-2", "ring-base-content")
          lastTarget = null
        }
      })

      this.el.addEventListener("drop", (e) => {
        const cell = e.target.closest("[data-drop-date]")
        if (!cell || !draggingId) return
        e.preventDefault()
        const newDate = cell.dataset.dropDate
        cell.classList.remove("ring-2", "ring-base-content")
        lastTarget = null
        this.pushEvent("move_event", {id: draggingId, date: newDate})
        draggingId = null
      })
    }
  },

  // Browser-style tab strip. Open routes are persisted client-side in
  // localStorage so they survive LiveView navigations; the dock buttons open
  // routes, and each open route shows up here as a tab with a close (×) button.
  TabStrip: {
    mounted() {
      this.labels = this.parseLabels()
      this.el.addEventListener("click", (e) => this.onClick(e))
      // Drag one tab onto another to join them into a side-by-side split tab.
      this.el.addEventListener("dragstart", (e) => this.onDragStart(e))
      this.el.addEventListener("dragover", (e) => this.onDragOver(e))
      this.el.addEventListener("drop", (e) => this.onDrop(e))
      // Right-click a tab for the context menu (Join tabs, ...).
      this.el.addEventListener("contextmenu", (e) => this.onContextMenu(e))
      this.onNav = () => {this.closeMenu(); this.sync(); this.render()}
      // Re-render on every LiveView navigation so the active tab tracks the URL.
      window.addEventListener("phx:page-loading-stop", this.onNav)
      // BrowseLive pushes the loaded page's title/url so the tab reflects it.
      this.handleEvent("bc:tab_meta", (m) => this.onTabMeta(m))
      this.sync()
      this.render()
    },
    destroyed() {
      this.closeMenu()
      window.removeEventListener("phx:page-loading-stop", this.onNav)
    },
    parseLabels() {
      try { return JSON.parse(this.el.dataset.labels || "{}") } catch (_e) { return {} }
    },
    load() {
      try { return JSON.parse(localStorage.getItem("bc:tabs")) || [] } catch (_e) { return [] }
    },
    save(tabs) { localStorage.setItem("bc:tabs", JSON.stringify(tabs)) },
    // Tab key is the full path incl. query, so multiple /browse tabs
    // (each /browse?t=<id>) are distinct, independent tabs.
    currentKey() { return window.location.pathname + window.location.search },
    labelFor(key) {
      const [path, query] = key.split("?")
      if (path === "/split") {
        const params = new URLSearchParams(query || "")
        return `${this.shortLabel(params.get("left"))} | ${this.shortLabel(params.get("right"))}`
      }
      return this.labels[path] || path
    },
    shortLabel(fullPath) {
      if (!fullPath) return "?"
      const path = fullPath.split("?")[0]
      return this.labels[path] || path
    },
    sync() {
      const key = this.currentKey()
      const tabs = this.load()
      if (!tabs.some((t) => t.path === key)) {
        tabs.push({path: key, label: this.labelFor(key)})
        this.save(tabs)
      }
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
    render() {
      const active = this.currentKey()
      const tabs = this.load().map((t) => this.tabHtml(t, t.path === active)).join("")
      this.el.innerHTML = tabs + this.newTabHtml()
    },
    newTabHtml() {
      return `<button type="button" data-newtab="1" title="New browser tab" aria-label="New browser tab" ` +
        `class="grid size-7 shrink-0 place-items-center self-center rounded-sm text-base-content/60 hover:bg-base-content/10 hover:text-primary">` +
        `<span class="text-lg leading-none">+</span></button>`
    },
    tabHtml(tab, isActive) {
      const wrap = isActive
        ? "group flex shrink-0 items-center gap-1 rounded-t-lg border border-b-0 border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium text-base-content"
        : "group flex shrink-0 items-center gap-1 rounded-t-lg border border-transparent bg-base-200 px-3 py-1.5 text-sm text-base-content/60 hover:bg-base-100/70 hover:text-base-content"
      const label = this.escape(tab.label)
      const path = this.escape(tab.path)
      return `<span class="${wrap}" data-path="${path}" draggable="true">` +
        `<a href="${path}" draggable="false" data-phx-link="redirect" data-phx-link-state="push" class="max-w-[12rem] truncate">${label}</a>` +
        `<button type="button" data-close="${path}" aria-label="Close ${label}" ` +
        `class="grid size-4 shrink-0 place-items-center rounded text-base-content/40 hover:bg-base-300 hover:text-base-content">&times;</button>` +
        `</span>`
    },
    onClick(e) {
      const newTab = e.target.closest("[data-newtab]")
      if (newTab) {
        e.preventDefault()
        this.openBrowserTab()
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
      window.location.href = `/split?left=${encodeURIComponent(left)}&right=${encodeURIComponent(right)}`
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
      window.location.href = newPath
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
      window.location.href = left
    },
    // ----- Right-click context menu -----
    onContextMenu(e) {
      const tab = e.target.closest("[data-path]")
      if (!tab) return
      e.preventDefault()
      this.openMenu(tab.getAttribute("data-path"), e.clientX, e.clientY)
    },
    openMenu(path, x, y) {
      this.closeMenu()
      this.menuPath = path
      const menu = document.createElement("div")
      menu.className =
        "fixed z-50 min-w-44 rounded-lg border border-base-300 bg-base-100 p-1 text-sm shadow-lg"
      menu.addEventListener("click", (e) => this.onMenuClick(e))
      menu.addEventListener("contextmenu", (e) => e.preventDefault())
      document.body.appendChild(menu)
      this.menuEl = menu
      this.renderMenuRoot()

      // Position at the cursor, clamped to the viewport.
      const rect = menu.getBoundingClientRect()
      const left = Math.max(8, Math.min(x, window.innerWidth - rect.width - 8))
      const top = Math.max(8, Math.min(y, window.innerHeight - rect.height - 8))
      menu.style.left = `${left}px`
      menu.style.top = `${top}px`

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
    renderMenuRoot() {
      const isSplit = (this.menuPath || "").split("?")[0] === "/split"
      const item = "flex w-full items-center gap-3 rounded px-3 py-1.5 text-left hover:bg-base-200"
      this.menuEl.innerHTML = isSplit
        ? `<button type="button" data-menu="swap" class="${item}"><span>Swap sides</span></button>` +
            `<button type="button" data-menu="separate" class="${item}"><span>Separate tabs</span></button>`
        : `<button type="button" data-menu="join" class="${item} justify-between">` +
            `<span>Join tabs</span><span class="text-base-content/40">&#9656;</span></button>`
    },
    renderJoinList() {
      const candidates = this.load().filter(
        (t) => t.path !== this.menuPath && !t.path.startsWith("/split")
      )
      const header =
        `<div class="px-3 py-1 text-xs font-semibold uppercase tracking-wide text-base-content/50">Join with…</div>`
      if (candidates.length === 0) {
        this.menuEl.innerHTML =
          header + `<div class="px-3 py-2 text-xs text-base-content/50">No other tabs open.</div>`
        return
      }
      const rows = candidates
        .map(
          (t) =>
            `<button type="button" data-jointarget="${this.escape(t.path)}" ` +
            `class="block w-full truncate rounded px-3 py-1.5 text-left hover:bg-base-200">${this.escape(t.label)}</button>`
        )
        .join("")
      this.menuEl.innerHTML = header + rows
    },
    onMenuClick(e) {
      const join = e.target.closest("[data-menu='join']")
      if (join) {
        e.stopPropagation()
        this.renderJoinList()
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
    closeTab(path) {
      const tabs = this.load()
      const idx = tabs.findIndex((t) => t.path === path)
      if (idx === -1) return
      tabs.splice(idx, 1)
      this.save(tabs)
      if (path === this.currentKey()) {
        const next = tabs[idx] || tabs[idx - 1]
        window.location.href = next ? next.path : "/"
      } else {
        this.render()
      }
    },
    escape(s) {
      return String(s).replace(/[&<>"']/g, (c) =>
        ({"&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;"}[c]))
    }
  },

  // PTY-backed terminal (desktop only). xterm.js renders here; the PTY lives in
  // the Tauri Rust backend, reached over IPC. In a plain browser (no Tauri) we
  // show a notice instead of a terminal.
  TerminalView: {
    async mounted() {
      const tauri = window.__TAURI__
      if (!tauri) {
        this.el.innerHTML =
          `<div class="grid h-full place-items-center p-8 text-center text-sm text-base-content/60">` +
          `Terminal is available in the Buster Claw desktop app.</div>`
        return
      }
      const {invoke} = tauri.core
      const {listen} = tauri.event

      // Pull the live Industrial Claw theme tokens so the terminal matches the
      // app surface in both dark and light modes.
      const css = getComputedStyle(document.documentElement)
      const token = (name, fallback) => (css.getPropertyValue(name).trim() || fallback)
      const bg = token("--color-base-100", "#121212")
      const fg = token("--color-base-content", "#fafafa")
      const accent = token("--color-primary", "#ff4d1c")

      const term = new XTerm({
        fontFamily: "'IBM Plex Mono', ui-monospace, SFMono-Regular, Menlo, monospace",
        fontSize: 13,
        cursorBlink: true,
        theme: {
          background: bg,
          foreground: fg,
          cursor: accent,
          cursorAccent: bg,
          selectionBackground: accent,
          selectionForeground: bg,
        },
      })
      const fit = new FitAddon()
      term.loadAddon(fit)
      term.open(this.el)
      fit.fit()
      this.term = term

      try {
        this.id = await invoke("terminal_open", {cols: term.cols, rows: term.rows})
      } catch (e) {
        term.write(`\r\n[failed to open terminal: ${e}]\r\n`)
        return
      }

      this.unlistenData = await listen(`terminal:data:${this.id}`, (ev) => term.write(ev.payload))
      this.unlistenExit = await listen(`terminal:exit:${this.id}`, () =>
        term.write("\r\n[process exited]\r\n"))
      term.onData((data) => invoke("terminal_input", {id: this.id, data}))

      this.resizeObserver = new ResizeObserver(() => {
        try { fit.fit() } catch (_e) { return }
        if (this.id) invoke("terminal_resize", {id: this.id, cols: term.cols, rows: term.rows})
      })
      this.resizeObserver.observe(this.el)
      term.focus()
    },
    destroyed() {
      this.resizeObserver?.disconnect()
      this.unlistenData?.()
      this.unlistenExit?.()
      if (this.id && window.__TAURI__) {
        window.__TAURI__.core.invoke("terminal_close", {id: this.id})
      }
      this.term?.dispose()
    },
  }
}

const documentsSidebarStorageKey = "bc:documents-sidebar"
const setDocumentsSidebarState = (state) => {
  const nextState = state === "closed" ? "closed" : "open"
  document.documentElement.dataset.documentsSidebar = nextState
  localStorage.setItem(documentsSidebarStorageKey, nextState)
}

setDocumentsSidebarState(localStorage.getItem(documentsSidebarStorageKey))

window.addEventListener("storage", (event) => {
  if (event.key === documentsSidebarStorageKey) setDocumentsSidebarState(event.newValue)
})

window.addEventListener("bc:toggle-documents-sidebar", () => {
  const nextState = document.documentElement.dataset.documentsSidebar === "closed" ? "open" : "closed"
  setDocumentsSidebarState(nextState)
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
