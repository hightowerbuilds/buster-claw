// Drag clips around a multi-lane arrangement (SOUND_STUDIO_ROADMAP Phase 6).
//
// One hook on the lanes container, with event delegation, rather than a hook
// per clip: an arrangement can hold dozens of blocks, and dozens of hooks each
// binding window listeners is how a tab starts to feel heavy.
//
// The server owns the arrangement; this hook only reports moves. During a drag
// it nudges the block with a CSS transform for feedback and clears it on drop,
// so the position you end up seeing is always the one the server stored — never
// a client-side guess that quietly disagrees.

import {msAtRatio, dropStartMs, laneIndexAt} from "../lib/arrange.js"

export const TrackArrange = {
  mounted() {
    this.drag = null

    this.onDown = this.onDown.bind(this)
    this.onMove = this.onMove.bind(this)
    this.onUp = this.onUp.bind(this)

    this.el.addEventListener("pointerdown", this.onDown)
    window.addEventListener("pointermove", this.onMove)
    window.addEventListener("pointerup", this.onUp)
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onDown)
    window.removeEventListener("pointermove", this.onMove)
    window.removeEventListener("pointerup", this.onUp)
  },

  viewMs() {
    const ms = parseFloat(this.el.dataset.viewMs)
    return Number.isFinite(ms) && ms > 0 ? ms : 0
  },

  lanes() {
    return Array.from(this.el.querySelectorAll("[data-lane]"))
  },

  msAtX(clientX, laneEl) {
    const rect = laneEl.getBoundingClientRect()
    if (rect.width <= 0) return 0
    return msAtRatio((clientX - rect.left) / rect.width, this.viewMs())
  },

  onDown(event) {
    if (event.button !== 0) return
    const block = event.target.closest("[data-clip]")
    if (!block || this.viewMs() <= 0) return

    const laneEl = block.closest("[data-lane]")
    if (!laneEl) return

    event.preventDefault()

    const startMs = parseFloat(block.dataset.startMs) || 0

    this.drag = {
      block,
      clipId: block.dataset.clipId,
      // Where along the clip it was taken hold of, so a block grabbed by its
      // middle does not snap its left edge to the cursor on the first move.
      grabOffsetMs: this.msAtX(event.clientX, laneEl) - startMs,
      originX: event.clientX,
      laneEl,
    }

    block.classList.add("z-20", "opacity-80")
  },

  onMove(event) {
    if (!this.drag) return

    // Horizontal feedback only. Vertical movement changes which LANE the drop
    // targets, and lifting the block out of its row mid-drag would leave a hole
    // where the pointer no longer is.
    const dx = event.clientX - this.drag.originX
    this.drag.block.style.transform = `translateX(${dx}px)`

    const index = laneIndexAt(event.clientY, this.lanes().map((l) => l.getBoundingClientRect()))
    this.lanes().forEach((lane, i) => lane.toggleAttribute("data-lane-target", i === index))
  },

  onUp(event) {
    if (!this.drag) return
    const {block, clipId, grabOffsetMs, laneEl} = this.drag
    this.drag = null

    block.style.transform = ""
    block.classList.remove("z-20", "opacity-80")

    const lanes = this.lanes()
    lanes.forEach((lane) => lane.removeAttribute("data-lane-target"))

    const index = laneIndexAt(event.clientY, lanes.map((l) => l.getBoundingClientRect()))
    const targetLane = index >= 0 ? lanes[index] : laneEl

    // pushEventTo, not pushEvent: a hook's plain pushEvent goes to the parent
    // LiveView, and the arrangement lives in the live_component. The container
    // carries phx-target={@myself}, so passing the element routes it there.
    this.pushEventTo(this.el, "move_clip", {
      clip_id: clipId,
      lane_id: targetLane.dataset.laneId,
      start_ms: dropStartMs(this.msAtX(event.clientX, targetLane), grabOffsetMs),
    })
  },
}
