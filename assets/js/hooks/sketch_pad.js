// The Sketch Pad's pointer handling.
//
// SKETCH_ROADMAP Phase 1 moved the document to the server, so this no longer
// owns the drawing — it owns one stroke, for as long as that stroke is being
// made. `pointermove` fires per pixel and a round trip per point would be
// visible lag on the one interaction that has to feel immediate, so the finished
// points are pushed once, on `pointerup`.
//
// At any moment a stroke is exactly one of two things: in-flight and drawn here,
// or committed and drawn by LiveView. Never both, so there is no parallel model.
//
// All three tools live here rather than being split with `phx-click` on the
// elements, because a click handler and a pointerdown handler on the same node
// race each other and the loser is whichever the browser dispatches second.

import {extend, pathData, toPoint} from "../lib/sketch.js"

export default {
  mounted() {
    this.points = []
    this.drawing = false
    this.dragging = null

    this.onDown = (e) => this.down(e)
    this.onMove = (e) => this.move(e)
    this.onUp = (e) => this.up(e)

    this.el.addEventListener("pointerdown", this.onDown)
    this.el.addEventListener("pointermove", this.onMove)
    // On the window, not the element: releasing outside must still end the
    // stroke, or the next hover continues a line the user thought was finished.
    window.addEventListener("pointerup", this.onUp)
    window.addEventListener("pointercancel", this.onUp)
  },

  destroyed() {
    window.removeEventListener("pointerup", this.onUp)
    window.removeEventListener("pointercancel", this.onUp)
  },

  tool() {
    return this.el.dataset.sketchTool || "draw"
  },

  // The element under the pointer, if it is one of ours. In draw mode the
  // committed paths carry `pointer-events="none"` and their hit targets are not
  // rendered at all, so this is always null and a stroke can start anywhere.
  elementAt(e) {
    const hit = document.elementFromPoint(e.clientX, e.clientY)
    return hit && hit.dataset ? hit.dataset.sketchElement || null : null
  },

  down(e) {
    // Secondary buttons are for menus, and a right-drag that drew a line would
    // be a surprise in both directions.
    if (e.button !== 0) return

    const tool = this.tool()
    const id = this.elementAt(e)

    if (tool === "draw") return this.startStroke(e)
    if (tool === "erase") return this.erase(id)
    if (tool === "text") return this.placeText(e)

    if (tool === "select") {
      this.pushEventTo(this.el, "select", {id})
      // A drag is only armed on something real, so dragging empty space cannot
      // move whatever happened to be selected a moment ago.
      this.dragging = id ? {id, from: toPoint(e, this.rect())} : null
    }
  },

  move(e) {
    if (this.drawing) return this.extendStroke(e)
    if (this.tool() === "erase" && e.buttons === 1) return this.erase(this.elementAt(e))
  },

  up(e) {
    if (this.drawing) return this.endStroke()
    if (this.dragging) return this.endDrag(e)
  },

  // Queried rather than cached. LiveView patches this component on every commit,
  // and a reference captured in `mounted` is only valid until morphdom decides
  // to replace the node it points at — a staleness that shows up as a stroke
  // that silently stops drawing, long after the change that caused it.
  svg() {
    return this.el.querySelector("[data-sketch-svg]")
  },

  liveLayer() {
    return this.el.querySelector("[data-sketch-live]")
  },

  rect() {
    return this.svg().getBoundingClientRect()
  },

  // ------------------------------------------------------------------ drawing

  startStroke(e) {
    const live = this.liveLayer()

    this.drawing = true
    this.points = [toPoint(e, this.rect())]

    live.setAttribute("stroke", this.currentColor())
    live.setAttribute("stroke-width", this.currentWidth())
    live.setAttribute("d", pathData(this.points))
  },

  extendStroke(e) {
    const next = extend(this.points, toPoint(e, this.rect()))
    // `extend` returns the same array when the point was too close to keep, so
    // an unchanged stroke costs no attribute write.
    if (next === this.points) return

    this.points = next
    this.liveLayer().setAttribute("d", pathData(this.points))
  },

  endStroke() {
    this.drawing = false
    const points = this.points
    this.points = []

    if (points.length === 0) return

    // Clearing the in-flight layer BEFORE the server answers would blank the
    // stroke for one round trip. Clearing it once LiveView has painted the
    // committed element is what makes the handoff invisible.
    this.pushEventTo(this.el, "stroke", {points}, () =>
      this.liveLayer().setAttribute("d", ""),
    )
  },

  // The toolbar is server state; the hook reads what is currently pressed rather
  // than tracking its own copy, which is what stops the two from disagreeing.
  currentColor() {
    const pressed = document.querySelector("#studio-sketch [data-sketch-color][data-active]")
    return pressed ? pressed.dataset.sketchColor : "#F4F1EA"
  },

  currentWidth() {
    const pressed = document.querySelector("#studio-sketch [data-sketch-size][data-active]")
    return pressed ? pressed.dataset.sketchSize : "2"
  },

  // --------------------------------------------------------------------- text
  //
  // The toolbar's field is not a server assign — it is `phx-update="ignore"` and
  // carries no `value`, so what is in it belongs to the browser until this
  // click. Read here for the same reason the colour and the width are read here:
  // one source of truth for what is currently held, rather than a copy in the
  // hook that can disagree with what the toolbar shows.
  //
  // Deliberately NOT cleared afterwards. The field is a stamp — placing the same
  // label in three corners is a thing people do, and retyping it twice to prove
  // you meant it is not a safety property.

  placeText(e) {
    const field = this.textField()
    const [x, y] = toPoint(e, this.rect())

    this.pushEventTo(this.el, "text", {content: field ? field.value : "", x, y})
  },

  // Scoped to the pad, not the document: `#studio-sketch` is the pad's own
  // subtree, and a bare `[data-sketch-text]` would happily find a field another
  // tab left in the DOM.
  textField() {
    return document.querySelector("#studio-sketch [data-sketch-text]")
  },

  // ------------------------------------------------------------ erase and drag

  erase(id) {
    if (id) this.pushEventTo(this.el, "erase", {id})
  },

  endDrag(e) {
    const {id, from} = this.dragging
    this.dragging = null

    const to = toPoint(e, this.rect())
    const dx = to[0] - from[0]
    const dy = to[1] - from[1]

    // A click is a selection, not a zero-length move. Without this every select
    // would also push a move, costing a history entry that undoes nothing.
    if (dx === 0 && dy === 0) return

    this.pushEventTo(this.el, "move", {id, dx, dy})
  },
}
