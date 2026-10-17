import {panelGeometry, layoutDots, resizeTree, readLayout, saveLayout, leavesOf, relabelTree, reorderKeys} from "../lib/workbench.js"
import {requestNewTerminal, takeTerminalNewFlag, terminalHookIn} from "../lib/tabs.js"
import {clawConfirm} from "../lib/claw_confirm.js"

function position(el, box) {
  for (const [key, value] of Object.entries(box)) {
    if (["x", "y", "width", "height"].includes(key)) el.style.setProperty(`--pane-${key}`, `${value}px`)
  }
}

export const Workbench = {
  mounted() {
    this.root = this.el.closest("#workbench")
    this.canvas = this.root.querySelector("#workbench-canvas")
    this.dividers = this.root.querySelector("#workbench-dividers")
    this.state = JSON.parse(this.el.dataset.state)
    let saved = null
    try { this.storage = window.localStorage; saved = readLayout(this.storage) } catch { /* Storage can be disabled. */ }
    this.handleEvent("workbench:sync", state => {
      // While a divider or a panel is captured, local geometry leads; the final
      // resize/reorder event commits it. Focus acknowledgements must not
      // interrupt the drag.
      if (this.drag || this.paneDrag) return
      this.state = state
      saveLayout(this.storage, state)
      this.draw()
      window.dispatchEvent(new CustomEvent("bc:workbench-state", {detail: state}))
    })
    this.pushEvent("restore_workbench", {state: saved || this.state}, () => { this.el.dataset.ready = "true" })
    // ⌘T or the sidebar's Terminal from another app tab: open a slot on arrival.
    if (takeTerminalNewFlag()) this.pushEvent("workbench_terminal_new", {})
    this.handleEvent("workbench:limit", detail => window.dispatchEvent(new CustomEvent("bc:workbench-limit", {detail})))
    this.onTerminalNew = () => this.pushEvent("workbench_terminal_new", {})
    this.onClick = event => this.closeTerminal(event)
    this.onPointer = event => {
      const divider = event.target.closest("[data-workbench-divider]")
      if (divider) return this.startDrag(event, divider)
      const pane = event.target.closest("[data-workbench-pane]")
      if (pane && pane.dataset.workbenchPane !== this.state.active) {
        this.pushEvent("workbench_focus", {key: pane.dataset.workbenchPane})
      }
      // Pick a panel up by its header (not its buttons) — see armPaneDrag.
      const header = event.target.closest(".ic-workbench-pane-header")
      if (header && pane && !event.target.closest("button")) this.armPaneDrag(event, pane)
    }
    this.onKey = event => this.resizeWithKeys(event)
    this.onOpen = event => {
      if (typeof event.detail?.key === "string") this.pushEvent("select_home_tab", {tab: event.detail.key})
    }
    this.onLayout = event => {
      if (typeof event.detail?.preset === "string") this.pushEvent("workbench_layout", {preset: event.detail.preset})
    }
    this.root.addEventListener("pointerdown", this.onPointer)
    this.root.addEventListener("click", this.onClick)
    this.dividers.addEventListener("keydown", this.onKey)
    window.addEventListener("bc:workbench-open", this.onOpen)
    window.addEventListener("bc:workbench-layout", this.onLayout)
    window.addEventListener("bc:terminal-new", this.onTerminalNew)
    this.observer = new ResizeObserver(() => this.draw())
    this.observer.observe(this.canvas)
    this.draw()
  },
  draw() {
    const narrow = this.canvas.clientWidth < 560
    this.canvas.dataset.stacked = String(narrow)
    const geometry = panelGeometry(this.state.tree, this.canvas.clientWidth, this.canvas.clientHeight, this.state.zoom)
    for (const pane of this.canvas.querySelectorAll("[data-workbench-pane]")) {
      const key = pane.dataset.workbenchPane
      // A lifted panel follows the pointer; its slot is drawn by the others.
      if (this.paneDrag?.lifted && key === this.paneDrag.key) continue
      if (geometry.panes[key]) position(pane, geometry.panes[key])
    }
    if (this.drag) return
    const focused = document.activeElement?.dataset.workbenchDivider
    this.dividers.replaceChildren()
    if (narrow) return
    for (const divider of geometry.dividers) {
      const el = document.createElement("div")
      el.className = "ic-workbench-divider"
      el.dataset.workbenchDivider = JSON.stringify(divider.path)
      el.dataset.axis = divider.axis
      el.tabIndex = 0
      el.setAttribute("role", "separator")
      el.setAttribute("aria-label", "Resize panels")
      el.setAttribute("aria-orientation", divider.axis === "horizontal" ? "vertical" : "horizontal")
      el.setAttribute("aria-valuenow", Math.round(divider.ratio * 100))
      el.setAttribute("aria-valuemin", "15")
      el.setAttribute("aria-valuemax", "85")
      position(el, divider)
      this.dividers.appendChild(el)
      if (focused === el.dataset.workbenchDivider) el.focus({preventScroll: true})
    }
  },
  divider(path) {
    return panelGeometry(this.state.tree, this.canvas.clientWidth, this.canvas.clientHeight)
      .dividers.find(item => JSON.stringify(item.path) === JSON.stringify(path))
  },
  startDrag(event, el) {
    if (event.button !== 0) return
    const path = JSON.parse(el.dataset.workbenchDivider)
    const divider = this.divider(path)
    if (!divider) return
    event.preventDefault()
    this.drag = {path, divider, tree: this.state.tree}
    this.root.classList.add("is-resizing")
    el.setPointerCapture(event.pointerId)
    this.onMove = move => {
      const rect = this.canvas.getBoundingClientRect()
      const horizontal = divider.axis === "horizontal"
      const offset = horizontal ? move.clientX - rect.left - divider.bounds.x : move.clientY - rect.top - divider.bounds.y
      const size = horizontal ? divider.bounds.width : divider.bounds.height
      if (size <= 8) return
      this.drag.ratio = Math.max(0.15, Math.min(0.85, (offset - 4) / (size - 8)))
      this.state = {...this.state, tree: resizeTree(this.drag.tree, path, this.drag.ratio)}
      const geometry = panelGeometry(this.state.tree, this.canvas.clientWidth, this.canvas.clientHeight)
      for (const node of this.dividers.children) {
        const current = geometry.dividers.find(d => JSON.stringify(d.path) === node.dataset.workbenchDivider)
        if (current) position(node, current)
      }
      this.draw()
    }
    this.onEnd = () => {
      const drag = this.drag
      this.stopDrag()
      if (drag?.ratio) this.pushEvent("workbench_resize", {path, ratio: drag.ratio})
      this.draw()
    }
    this.dragElement = el
    el.addEventListener("pointermove", this.onMove)
    el.addEventListener("pointerup", this.onEnd, {once: true})
    el.addEventListener("pointercancel", this.onEnd, {once: true})
  },
  stopDrag() {
    this.dragElement?.removeEventListener("pointermove", this.onMove)
    this.dragElement?.removeEventListener("pointerup", this.onEnd)
    this.dragElement?.removeEventListener("pointercancel", this.onEnd)
    this.drag = null
    this.root.classList.remove("is-resizing")
  },
  // × on a terminal pane (TERMINAL_PANELS D4): ask if something is running,
  // end the shell for good, then let the server drop the slot. `destroyed()`
  // alone would keep the PTY for a reattach, and the next terminal opened in
  // this slot would wake up inside it.
  async closeTerminal(event) {
    const button = event.target.closest("[data-workbench-close-terminal]")
    if (!button) return
    event.preventDefault()
    const key = button.dataset.workbenchCloseTerminal
    const hook = terminalHookIn(this.canvas.querySelector(`[data-workbench-pane="${key}"]`))
    if (hook && (await hook.isBusy()) && !(await clawConfirm("This terminal is running something. Close it anyway?"))) return
    if (hook) await hook.closeSession()
    this.pushEvent("workbench_close", {key})
  },
  // ---- Drag a panel to a new spot -------------------------------------------
  // Pointer down on a header arms it; moving a few pixels lifts the panel.
  // While lifted it follows the pointer, and whichever panel it hovers slides
  // over: the order is recomputed and the tree relabelled locally
  // (`reorderKeys` + `relabelTree`), so the preview is the exact final layout.
  // The drop sends `workbench_reorder` with the order; Escape puts it back.
  // Not while zoomed (one panel, nowhere to go) nor on a narrow canvas (the
  // panes are a column there and the geometry does not apply).
  armPaneDrag(event, pane) {
    if (event.button !== 0 || this.state.zoom || this.canvas.dataset.stacked === "true") return
    if (leavesOf(this.state.tree).length < 2) return
    this.paneDrag = {key: pane.dataset.workbenchPane, pane, x: event.clientX, y: event.clientY, pointerId: event.pointerId, lifted: false}
    this.onPaneMove = move => this.movePane(move)
    this.onPaneUp = () => this.dropPane(false)
    this.onPaneKey = key => { if (key.key === "Escape") this.dropPane(true) }
    window.addEventListener("pointermove", this.onPaneMove)
    window.addEventListener("pointerup", this.onPaneUp)
    window.addEventListener("pointercancel", this.onPaneUp)
    window.addEventListener("keydown", this.onPaneKey, true)
  },
  movePane(move) {
    const drag = this.paneDrag
    if (!drag) return
    if (!drag.lifted) {
      if (Math.hypot(move.clientX - drag.x, move.clientY - drag.y) < 6) return
      const rect = drag.pane.getBoundingClientRect()
      const canvas = this.canvas.getBoundingClientRect()
      Object.assign(drag, {
        lifted: true,
        tree: this.state.tree,
        order: leavesOf(this.state.tree),
        start: leavesOf(this.state.tree),
        grabX: drag.x - rect.left,
        grabY: drag.y - rect.top,
        canvas,
      })
      try { drag.pane.setPointerCapture(drag.pointerId) } catch { /* capture is a nicety */ }
      drag.pane.classList.add("is-lifted")
      this.root.dataset.paneDragging = "true"
    }
    move.preventDefault()
    const px = move.clientX - drag.canvas.left
    const py = move.clientY - drag.canvas.top
    position(drag.pane, {x: px - drag.grabX, y: py - drag.grabY})
    const geometry = panelGeometry(this.state.tree, this.canvas.clientWidth, this.canvas.clientHeight)
    const target = Object.entries(geometry.panes).find(([key, box]) =>
      key !== drag.key && px >= box.x && px <= box.x + box.width && py >= box.y && py <= box.y + box.height
    )?.[0]
    if (!target) return
    const order = reorderKeys(drag.order, drag.key, target)
    if (order === drag.order) return
    drag.order = order
    this.state = {...this.state, tree: relabelTree(drag.tree, order)}
    this.draw()
  },
  dropPane(cancelled) {
    const drag = this.paneDrag
    if (!drag) return
    window.removeEventListener("pointermove", this.onPaneMove)
    window.removeEventListener("pointerup", this.onPaneUp)
    window.removeEventListener("pointercancel", this.onPaneUp)
    window.removeEventListener("keydown", this.onPaneKey, true)
    this.paneDrag = null
    if (!drag.lifted) return
    try { drag.pane.releasePointerCapture(drag.pointerId) } catch { /* already released */ }
    drag.pane.classList.remove("is-lifted")
    delete this.root.dataset.paneDragging
    if (cancelled) this.state = {...this.state, tree: drag.tree}
    this.draw()
    // Always commit: a sync that arrived mid-drag (the focus acknowledgement)
    // was held back, and the reply to this one brings the state current.
    this.pushEvent("workbench_reorder", {order: cancelled ? drag.start : drag.order})
  },
  resizeWithKeys(event) {
    const el = event.target.closest("[data-workbench-divider]")
    if (!el) return
    const keys = el.dataset.axis === "horizontal" ? ["ArrowLeft", "ArrowRight"] : ["ArrowUp", "ArrowDown"]
    if (!keys.includes(event.key)) return
    event.preventDefault()
    const path = JSON.parse(el.dataset.workbenchDivider)
    const divider = this.divider(path)
    if (divider) this.pushEvent("workbench_resize", {path, ratio: divider.ratio + (event.key === keys[0] ? -0.05 : 0.05)})
  },
  destroyed() {
    this.stopDrag()
    this.dropPane(true)
    this.observer.disconnect()
    this.root.removeEventListener("pointerdown", this.onPointer)
    this.root.removeEventListener("click", this.onClick)
    this.dividers.removeEventListener("keydown", this.onKey)
    window.removeEventListener("bc:workbench-open", this.onOpen)
    window.removeEventListener("bc:workbench-layout", this.onLayout)
    window.removeEventListener("bc:terminal-new", this.onTerminalNew)
  },
}

// The menu survives LiveView navigation. On the work area its links open
// panels; elsewhere the same links navigate back to the requested panel.
export const WorkbenchMenu = {
  mounted() {
    this.root = null
    this.onClick = event => {
      const layout = event.target.closest("[data-workbench-layout]")
      if (layout && !layout.disabled && document.querySelector("#workbench-controller")) {
        window.dispatchEvent(new CustomEvent("bc:workbench-layout", {detail: {preset: layout.dataset.workbenchLayout}}))
        return
      }
      if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
      // Terminal always creates (TERMINAL_PANELS D3) — here or on arrival.
      if (event.target.closest("[data-workbench-terminal-new]")) {
        event.preventDefault()
        event.stopImmediatePropagation()
        requestNewTerminal()
        return
      }
      const link = event.target.closest("[data-workbench-open]")
      if (!link || !document.querySelector("#workbench-controller")) return
      event.preventDefault()
      event.stopImmediatePropagation()
      window.dispatchEvent(new CustomEvent("bc:workbench-open", {detail: {key: link.dataset.workbenchOpen}}))
    }
    this.onState = event => {this.state = event.detail; this.bindRoot(); this.paint()}
    this.onNavigate = () => {this.bindRoot(); this.paint()}
    // A click at the limit: the server refused, the button says so for a beat.
    this.onLimit = () => {
      const button = this.root?.querySelector("[data-workbench-terminal-new]")
      if (!button) return
      button.classList.remove("is-refused")
      void button.offsetWidth
      button.classList.add("is-refused")
    }
    this.bindRoot()
    window.addEventListener("bc:workbench-state", this.onState)
    window.addEventListener("bc:workbench-limit", this.onLimit)
    window.addEventListener("phx:page-loading-stop", this.onNavigate)
    try { this.state = readLayout(window.localStorage) } catch { this.state = null }
    this.paint()
  },
  bindRoot() {
    // The menu is sticky, but the surrounding layout (including the picker)
    // is replaced on navigation. Listen on its current sidebar each time.
    const root = this.el.closest("#app-sidebar")
    if (!root) return
    if (root !== this.root) {
      this.root?.removeEventListener("click", this.onClick, true)
      this.root = root
      this.root.addEventListener("click", this.onClick, true)
      this.defaultLayouts = JSON.parse(this.root.querySelector("#workbench-layout-picker").dataset.layouts)
    }
  },
  paint() {
    if (!this.root?.isConnected) return
    const onWorkArea = Boolean(document.querySelector("#workbench-controller"))
    const open = new Set()
    const visit = (node, depth = 0) => {
      if (depth > 8) return
      if (typeof node === "string") open.add(node)
      else if (node && typeof node === "object") {visit(node.first, depth + 1); visit(node.second, depth + 1)}
    }
    visit(this.state?.tree)
    for (const link of this.root.querySelectorAll("[data-workbench-open]")) {
      const key = link.dataset.workbenchOpen
      link.dataset.active = String(onWorkArea && this.state?.active === key)
      link.querySelector(".ic-workbench-open-dot").hidden = !open.has(key)
    }
    const terminal = this.root.querySelector("[data-workbench-terminal-new]")
    if (terminal) {
      const count = [...open].filter(key => key === "terminal" || key.startsWith("terminal-")).length
      const limit = Number(this.state?.terminal_limit) || 4
      const badge = terminal.querySelector("[data-workbench-terminal-count]")
      badge.textContent = `${count} / ${limit}`
      badge.hidden = !(onWorkArea && count > 0)
      terminal.dataset.atLimit = String(onWorkArea && count >= limit)
      terminal.title = onWorkArea && count >= limit
        ? `${limit} terminals is the limit — close one to open another`
        : "Open a terminal"
    }
    this.root.querySelector("#workbench-browser").dataset.active = String(location.pathname === "/browse")
    this.root.querySelector("#workbench-settings").dataset.active = String(["/appearance", "/settings", "/notify-settings", "/security"].includes(location.pathname))
    for (const layout of this.state?.layouts || this.defaultLayouts) {
      const button = this.root.querySelector(`#workbench-layout-${layout.key}`)
      button.disabled = !onWorkArea || !layout.enabled
      button.setAttribute("aria-pressed", String(onWorkArea && this.state?.preset === layout.key && layout.enabled))
      button.title = !onWorkArea ? "Open a panel to arrange your work area"
        : !layout.enabled ? `${layout.label} — ${layout.hint}`
        : `${layout.label} — ${open.size} panels`
      const dots = layoutDots(layout.tree).map(point => {
        const dot = document.createElement("span")
        dot.style.left = `${point.x}%`
        dot.style.top = `${point.y}%`
        return dot
      })
      button.querySelector(".ic-workbench-layout-dots").replaceChildren(...dots)
    }
  },
  destroyed() {
    this.root.removeEventListener("click", this.onClick, true)
    window.removeEventListener("bc:workbench-state", this.onState)
    window.removeEventListener("bc:workbench-limit", this.onLimit)
    window.removeEventListener("phx:page-loading-stop", this.onNavigate)
  },
}
