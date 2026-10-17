import {areaIdForPath, areaPath, reconcileAreaTabs} from "../lib/work_areas.js"
import {readLayout} from "../lib/workbench.js"

export const TabWorkAreas = {
  setupWorkAreas() {
    this.onAreaState = event => {
      this.save(reconcileAreaTabs(this.load(), event.detail))
      this.render()
    }
    window.addEventListener("bc:workbench-state", this.onAreaState)
    try {
      const state = readLayout(window.localStorage)
      if (state) this.save(reconcileAreaTabs(this.load(), state))
    } catch { /* storage disabled */ }
  },
  closeWorkArea(path) {
    const id = areaIdForPath(path)
    if (!id) return false
    if (id === "area-1") return true
    if (document.querySelector("#workbench-controller")) {
      window.dispatchEvent(new CustomEvent("bc:workbench-close-area", {detail: {id}}))
    } else {
      window.location.href = `${areaPath(id)}&close_area=${encodeURIComponent(id)}`
    }
    return true
  },
  navigateTab(path) {
    const id = areaIdForPath(path)
    if (id && window.location.pathname === "/" && document.querySelector("#workbench-controller")) {
      window.dispatchEvent(new CustomEvent("bc:workbench-select-area", {detail: {id}}))
    } else window.location.href = path
  },
}
