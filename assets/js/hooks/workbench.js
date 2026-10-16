import {panelGeometry, layoutDots, resizeTree, readLayout, saveLayout} from "../lib/workbench.js"

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
      // While a divider is captured, local geometry leads; the final resize
      // event commits it. Focus acknowledgements must not interrupt the drag.
      if (this.drag) return
      this.state = state
      saveLayout(this.storage, state)
      this.draw()
      window.dispatchEvent(new CustomEvent("bc:workbench-state", {detail: state}))
    })
    this.pushEvent("restore_workbench", {state: saved || this.state}, () => { this.el.dataset.ready = "true" })
    this.onPointer = event => {
      const divider = event.target.closest("[data-workbench-divider]")
      if (divider) return this.startDrag(event, divider)
      const pane = event.target.closest("[data-workbench-pane]")
      if (pane && pane.dataset.workbenchPane !== this.state.active) {
        this.pushEvent("workbench_focus", {key: pane.dataset.workbenchPane})
      }
    }
    this.onKey = event => this.resizeWithKeys(event)
    this.onOpen = event => {
      if (typeof event.detail?.key === "string") this.pushEvent("select_home_tab", {tab: event.detail.key})
    }
    this.onLayout = event => {
      if (typeof event.detail?.preset === "string") this.pushEvent("workbench_layout", {preset: event.detail.preset})
    }
    this.root.addEventListener("pointerdown", this.onPointer)
    this.dividers.addEventListener("keydown", this.onKey)
    window.addEventListener("bc:workbench-open", this.onOpen)
    window.addEventListener("bc:workbench-layout", this.onLayout)
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
    this.observer.disconnect()
    this.root.removeEventListener("pointerdown", this.onPointer)
    this.dividers.removeEventListener("keydown", this.onKey)
    window.removeEventListener("bc:workbench-open", this.onOpen)
    window.removeEventListener("bc:workbench-layout", this.onLayout)
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
      const link = event.target.closest("[data-workbench-open]")
      if (!link || !document.querySelector("#workbench-controller") || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
      event.preventDefault()
      event.stopImmediatePropagation()
      window.dispatchEvent(new CustomEvent("bc:workbench-open", {detail: {key: link.dataset.workbenchOpen}}))
    }
    this.onState = event => {this.state = event.detail; this.bindRoot(); this.paint()}
    this.onNavigate = () => {this.bindRoot(); this.paint()}
    this.bindRoot()
    window.addEventListener("bc:workbench-state", this.onState)
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
    this.root.querySelector("#workbench-browser").dataset.active = String(location.pathname === "/browse")
    this.root.querySelector("#workbench-settings").dataset.active = String(["/appearance", "/settings", "/notify-settings", "/integrations", "/security"].includes(location.pathname))
    for (const layout of this.state?.layouts || this.defaultLayouts) {
      const button = this.root.querySelector(`#workbench-layout-${layout.key}`)
      button.disabled = !onWorkArea || !layout.enabled
      button.setAttribute("aria-pressed", String(onWorkArea && this.state?.preset === layout.key && layout.enabled))
      button.title = !onWorkArea ? "Open a panel to arrange your work area"
        : !layout.enabled ? `${layout.label} — open ${layout.key === "grid" ? "three" : "two"} panels to use`
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
    window.removeEventListener("phx:page-loading-stop", this.onNavigate)
  },
}
