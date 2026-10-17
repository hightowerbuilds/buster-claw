import {leavesOf, panelGeometry, relabelTree, reorderKeys} from "../lib/workbench.js"
import {moveFrame, positionPane} from "../lib/workbench_overlap.js"

export const WorkbenchDrag = {
  armPaneDrag(event, pane) {
    if (event.button !== 0 || this.state.zoom || this.canvas.dataset.stacked === "true") return
    if (this.state.mode !== "overlap" && leavesOf(this.state.tree).length < 2) return
    if (this.paneDrag) this.dropPane(true)
    this.paneDrag = this.dragSnapshot(pane, {x: event.clientX, y: event.clientY, pointerId: event.pointerId})
    this.onPaneMove = move => this.movePane(move)
    this.onPaneUp = () => this.dropPane(false)
    this.onPaneCancel = () => this.dropPane(true)
    this.onPaneKey = key => {
      if (key.key === "Escape") { key.preventDefault(); this.dropPane(true) }
    }
    window.addEventListener("pointermove", this.onPaneMove)
    window.addEventListener("pointerup", this.onPaneUp)
    window.addEventListener("pointercancel", this.onPaneCancel)
    window.addEventListener("blur", this.onPaneCancel)
    window.addEventListener("keydown", this.onPaneKey, true)
    pane.addEventListener("lostpointercapture", this.onPaneCancel)
  },
  dragSnapshot(pane, extra = {}) {
    const key = pane.dataset.workbenchPane
    return {key, pane, tree: this.state.tree, start: leavesOf(this.state.tree), order: leavesOf(this.state.tree),
      mode: this.state.mode, frame: this.state.frames?.[key], startFrame: this.state.frames?.[key],
      area_id: this.state.active_area_id, revision: this.state.revision, lifted: false, ...extra}
  },
  movePane(move) {
    const drag = this.paneDrag
    if (!drag || drag.keyboard || move.pointerId !== drag.pointerId) return
    if (!drag.lifted) {
      if (Math.hypot(move.clientX - drag.x, move.clientY - drag.y) < 6) return
      const rect = drag.pane.getBoundingClientRect()
      Object.assign(drag, {lifted: true, grabX: drag.x - rect.left, grabY: drag.y - rect.top,
        canvas: this.canvas.getBoundingClientRect()})
      try { drag.pane.setPointerCapture(drag.pointerId) } catch { /* already released */ }
      drag.pane.classList.add("is-lifted")
      drag.pane.style.zIndex = "10"
      this.root.dataset.paneDragging = "true"
    }
    move.preventDefault()
    if (drag.mode === "overlap") {
      drag.frame = moveFrame(drag.startFrame, move.clientX - drag.x, move.clientY - drag.y,
        drag.canvas.width, drag.canvas.height)
      this.drawFloatingDrag(drag)
      return
    }
    const px = move.clientX - drag.canvas.left
    const py = move.clientY - drag.canvas.top
    positionPane(drag.pane, {x: px - drag.grabX, y: py - drag.grabY})
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
  drawFloatingDrag(drag) {
    this.state = {...this.state, frames: {...this.state.frames, [drag.key]: drag.frame}}
    positionPane(drag.pane, {x: drag.frame.x * this.canvas.clientWidth, y: drag.frame.y * this.canvas.clientHeight})
  },
  dropPane(cancelled, commit = true) {
    const drag = this.paneDrag
    if (!drag) return
    this.paneDrag = null
    window.removeEventListener("pointermove", this.onPaneMove)
    window.removeEventListener("pointerup", this.onPaneUp)
    window.removeEventListener("pointercancel", this.onPaneCancel)
    window.removeEventListener("blur", this.onPaneCancel)
    window.removeEventListener("keydown", this.onPaneKey, true)
    drag.pane.removeEventListener("lostpointercapture", this.onPaneCancel)
    try { drag.pane.releasePointerCapture(drag.pointerId) } catch { /* not captured */ }
    drag.pane.classList.remove("is-lifted")
    delete this.root.dataset.paneDragging
    if (this.pendingState) { const next = this.pendingState; this.pendingState = null; this.receiveState(next) }
    // A deferred focus acknowledgement carries the old geometry. Keep the
    // released frame visible while its final server acknowledgement arrives.
    this.state = drag.mode === "overlap"
      ? {...this.state, frames: {...this.state.frames, [drag.key]: cancelled ? drag.startFrame : drag.frame}}
      : {...this.state, tree: relabelTree(drag.tree, cancelled ? drag.start : drag.order)}
    this.draw()
    if (!commit || !drag.lifted) return
    if (drag.mode === "overlap") {
      this.pushEvent("workbench_move", {key: drag.key, frame: cancelled ? drag.startFrame : drag.frame,
        area_id: drag.area_id, revision: drag.revision})
    } else {
      this.pushEvent("workbench_reorder", {order: cancelled ? drag.start : drag.order,
        area_id: drag.area_id, revision: drag.revision})
    }
  },
  moveWithKeys(event) {
    const title = event.target.closest(".ic-workbench-pane-header h2")
    if (!title || this.state.mode !== "overlap" || this.state.zoom || this.canvas.dataset.stacked === "true") return
    if (this.paneDrag?.keyboard && ["Escape", "Enter"].includes(event.key)) {
      event.preventDefault(); this.dropPane(event.key === "Escape"); return
    }
    const delta = {ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1]}[event.key]
    if (!delta) return
    event.preventDefault()
    if (!this.paneDrag) this.paneDrag = this.dragSnapshot(title.closest("[data-workbench-pane]"), {keyboard: true, lifted: true})
    const drag = this.paneDrag
    if (!drag.keyboard) return
    const step = event.shiftKey ? 30 : 10
    drag.frame = moveFrame(drag.frame, delta[0] * step, delta[1] * step, this.canvas.clientWidth, this.canvas.clientHeight)
    this.drawFloatingDrag(drag)
  },
}
