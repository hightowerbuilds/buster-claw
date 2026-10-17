import {saveLayout} from "../lib/workbench.js"
import {areaTerminalKeys} from "../lib/work_areas.js"
import {terminalHookIn} from "../lib/tabs.js"
import {clawConfirm} from "../lib/claw_confirm.js"

export const WorkbenchAreas = {
  receiveState(state) {
    if (this.drag || this.paneDrag) {
      if (state.revision === this.state.revision && state.active_area_id === this.state.active_area_id) {
        this.pendingState = state
        return
      }
      this.pendingState = null
      this.stopDrag()
      this.dropPane(true, false)
    }
    this.pendingState = null
    const priorArea = this.state?.active_area_id
    this.state = state
    if (!saveLayout(this.storage, state)) this.notice("Your arrangement works for this session, but cannot be saved on this device.")
    this.draw()
    window.dispatchEvent(new CustomEvent("bc:workbench-state", {detail: state}))
    if (priorArea !== state.active_area_id) {
      requestAnimationFrame(() => {
        const pane = this.canvas.querySelector(`[data-workbench-pane="${state.active}"]`)
        pane?.querySelector("h2")?.focus({preventScroll: true})
      })
    }
  },
  setupAreas() {
    this.onAreaClose = event => this.closeArea(event.detail.id)
    this.onAreaSelect = event => this.pushEvent("workbench_select_area", {id: event.detail.id})
    this.onMode = event => {
      this.dropPane(true, false)
      this.pushEvent("workbench_mode", {mode: event.detail.mode})
    }
    this.onReset = () => this.pushEvent("workbench_reset_positions", {})
    this.onFocusOut = event => {
      if (this.paneDrag?.keyboard && !this.paneDrag.pane.contains(event.relatedTarget)) this.dropPane(false)
    }
    window.addEventListener("bc:workbench-close-area", this.onAreaClose)
    window.addEventListener("bc:workbench-select-area", this.onAreaSelect)
    window.addEventListener("bc:workbench-mode", this.onMode)
    window.addEventListener("bc:workbench-reset", this.onReset)
    this.root.addEventListener("focusout", this.onFocusOut)
  },
  notice(message) {
    const el = this.root.querySelector("#workbench-notice")
    el.textContent = message
    el.hidden = false
  },
  consumeCloseIntent() {
    const id = new URLSearchParams(window.location.search).get("close_area")
    if (!id) return
    this.pushEvent("workbench_clear_intent", {}, () => this.closeArea(id))
  },
  async closeArea(id) {
    if (id === "area-1" || this.closingArea || !this.state.areas?.some(area => area.id === id)) return
    this.closingArea = true
    try {
      const hooks = areaTerminalKeys(this.state, id).map(key =>
        terminalHookIn(this.canvas.querySelector(`[data-workbench-pane="${key}"]`))).filter(Boolean)
      const busy = await Promise.all(hooks.map(hook => hook.isBusy()))
      if (busy.some(Boolean) && !(await clawConfirm("This work area has running terminals. Close the area and its terminals?"))) return
      for (const hook of hooks) await hook.closeSession()
      this.pushEvent("workbench_close_area", {id})
    } finally { this.closingArea = false }
  },
  destroyAreas() {
    window.removeEventListener("bc:workbench-close-area", this.onAreaClose)
    window.removeEventListener("bc:workbench-select-area", this.onAreaSelect)
    window.removeEventListener("bc:workbench-mode", this.onMode)
    window.removeEventListener("bc:workbench-reset", this.onReset)
    this.root.removeEventListener("focusout", this.onFocusOut)
  },
}
