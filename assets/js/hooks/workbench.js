import {panelGeometry, resizeTree, readLayout} from "../lib/workbench.js"
import {workbenchGeometry, positionPane as position} from "../lib/workbench_overlap.js"
import {WorkbenchDrag} from "./workbench_drag.js"
import {WorkbenchAreas} from "./workbench_areas.js"
export {WorkbenchMenu} from "./workbench_menu.js"
import {takeTerminalNewFlag, terminalHookIn} from "../lib/tabs.js"
import {clawConfirm} from "../lib/claw_confirm.js"

export const Workbench = {
  ...WorkbenchDrag,
  ...WorkbenchAreas,
  mounted() {
    this.root = this.el.closest("#workbench")
    this.canvas = this.root.querySelector("#workbench-canvas")
    this.dividers = this.root.querySelector("#workbench-dividers")
    this.state = JSON.parse(this.el.dataset.state)
    let saved = null
    try { this.storage = window.localStorage; saved = readLayout(this.storage) } catch { /* Storage can be disabled. */ }
    this.handleEvent("workbench:sync", state => this.receiveState(state))
    this.setupAreas()
    this.handleEvent("workbench:navigate-area", ({path}) => { window.location.href = path })
    const createTerminal = takeTerminalNewFlag()
    this.pushEvent("restore_workbench", {state: saved || this.state, create_terminal: createTerminal}, () => {
      this.el.dataset.ready = "true"
      this.consumeCloseIntent()
    })
    this.handleEvent("workbench:limit", () => this.notice("This workspace has reached its 64 work area limit. Close an area to make room."))
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
    this.onKey = event => { this.resizeWithKeys(event); this.moveWithKeys(event) }
    this.onFocus = event => {
      const pane = event.target.closest("[data-workbench-pane]")
      if (pane && pane.dataset.workbenchPane !== this.state.active) this.pushEvent("workbench_focus", {key: pane.dataset.workbenchPane})
    }
    this.onOpen = event => {
      if (typeof event.detail?.key === "string") this.pushEvent("select_home_tab", {tab: event.detail.key})
    }
    this.onLayout = event => {
      if (typeof event.detail?.preset === "string") this.pushEvent("workbench_layout", {preset: event.detail.preset})
    }
    this.root.addEventListener("pointerdown", this.onPointer)
    this.root.addEventListener("click", this.onClick)
    this.root.addEventListener("keydown", this.onKey)
    this.root.addEventListener("focusin", this.onFocus)
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
    this.canvas.dataset.mode = this.state.mode || "grid"
    window.dispatchEvent(new CustomEvent("bc:workbench-narrow", {detail: narrow}))
    const geometry = workbenchGeometry(this.state, this.canvas.clientWidth, this.canvas.clientHeight)
    for (const pane of this.canvas.querySelectorAll("[data-workbench-pane]")) {
      const key = pane.dataset.workbenchPane
      // A lifted panel follows the pointer; its slot is drawn by the others.
      if (this.paneDrag?.lifted && key === this.paneDrag.key) continue
      pane.style.zIndex = this.state.mode === "overlap" ? String(1 + (this.state.z_order || []).indexOf(key)) : ""
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
    this.drag = {path, divider, tree: this.state.tree, area_id: this.state.active_area_id, revision: this.state.revision}
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
      if (drag?.ratio) this.pushEvent("workbench_resize", {path, ratio: drag.ratio, area_id: drag.area_id, revision: drag.revision})
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
    this.dropPane(true, false)
    this.destroyAreas()
    this.observer.disconnect()
    this.root.removeEventListener("pointerdown", this.onPointer)
    this.root.removeEventListener("click", this.onClick)
    this.root.removeEventListener("keydown", this.onKey)
    this.root.removeEventListener("focusin", this.onFocus)
    window.removeEventListener("bc:workbench-open", this.onOpen)
    window.removeEventListener("bc:workbench-layout", this.onLayout)
    window.removeEventListener("bc:terminal-new", this.onTerminalNew)
  },
}
