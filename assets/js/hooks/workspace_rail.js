// The Workspace file tree's resize handle. Drag sets the rail's width live;
// release commits it to the server (`rail_resize`), which clamps and renders
// it, and remembers it here so the next visit starts where this one left off.
const KEY = "bc:workspace-rail"
const STEP = 16

export const WorkspaceRail = {
  mounted() {
    this.rail = () => this.el.querySelector("#workspace-tree-rail")
    let saved = null
    try { saved = Number(localStorage.getItem(KEY)) } catch { /* storage can be disabled */ }
    if (saved && saved !== Number(this.el.dataset.width)) this.pushEvent("rail_resize", {width: saved})
    this.onDown = event => {
      const handle = event.target.closest("[data-rail-handle]")
      if (!handle || event.button !== 0) return
      event.preventDefault()
      const rail = this.rail()
      const start = {x: event.clientX, width: rail.getBoundingClientRect().width}
      const move = ev => { rail.style.width = `${Math.max(120, start.width + ev.clientX - start.x)}px` }
      const up = () => {
        window.removeEventListener("pointermove", move)
        window.removeEventListener("pointerup", up)
        this.commit(rail.getBoundingClientRect().width)
      }
      window.addEventListener("pointermove", move)
      window.addEventListener("pointerup", up)
    }
    this.onKey = event => {
      if (!event.target.closest("[data-rail-handle]")) return
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return
      event.preventDefault()
      const width = this.rail().getBoundingClientRect().width + (event.key === "ArrowLeft" ? -STEP : STEP)
      this.commit(width)
    }
    this.el.addEventListener("pointerdown", this.onDown)
    this.el.addEventListener("keydown", this.onKey)
  },
  commit(width) {
    const px = Math.round(width)
    try { localStorage.setItem(KEY, String(px)) } catch { /* fine */ }
    this.pushEvent("rail_resize", {width: px})
  },
  destroyed() {
    this.el.removeEventListener("pointerdown", this.onDown)
    this.el.removeEventListener("keydown", this.onKey)
  },
}
