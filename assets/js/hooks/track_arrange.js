// Drag clips around a multi-track audio (SOUND_STUDIO_ROADMAP Phase 6).
//
// One hook on the tracks container, with event delegation, rather than a hook
// per clip: an audio can hold dozens of blocks, and dozens of hooks each
// binding window listeners is how a tab starts to feel heavy.
//
// The server owns the arrangement; this hook only reports moves. During a drag
// it nudges the block with a CSS transform for feedback and clears it on drop,
// so the position you end up seeing is always the one the server stored — never
// a client-side guess that quietly disagrees.

import {msAtRatio, dropStartMs, trackIndexAt, isClick} from "../lib/arrange.js"

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

  // The [data-track] element is the CLIP REGION of a row, not the whole row:
  // the control cluster sits to its left (the Pro Tools shape), and drop
  // arithmetic divides by this rect's width — include the cluster and every
  // drop lands early by its width.
  tracks() {
    return Array.from(this.el.querySelectorAll("[data-track]"))
  },

  msAtX(clientX, trackEl) {
    const rect = trackEl.getBoundingClientRect()
    if (rect.width <= 0) return 0
    return msAtRatio((clientX - rect.left) / rect.width, this.viewMs())
  },

  onDown(event) {
    if (event.button !== 0) return
    const block = event.target.closest("[data-clip]")
    if (!block || this.viewMs() <= 0) return

    const trackEl = block.closest("[data-track]")
    if (!trackEl) return

    event.preventDefault()

    const startMs = parseFloat(block.dataset.startMs) || 0

    this.drag = {
      block,
      clipId: block.dataset.clipId,
      // Where along the clip it was taken hold of, so a block grabbed by its
      // middle does not snap its left edge to the cursor on the first move.
      grabOffsetMs: this.msAtX(event.clientX, trackEl) - startMs,
      originX: event.clientX,
      originY: event.clientY,
      trackEl,
    }

    block.classList.add("z-20", "opacity-80")
  },

  onMove(event) {
    if (!this.drag) return

    // Horizontal feedback only. Vertical movement changes which TRACK the drop
    // targets, and lifting the block out of its row mid-drag would leave a hole
    // where the pointer no longer is.
    const dx = event.clientX - this.drag.originX
    this.drag.block.style.transform = `translateX(${dx}px)`

    const index = trackIndexAt(event.clientY, this.tracks().map((t) => t.getBoundingClientRect()))
    this.tracks().forEach((track, i) => track.toggleAttribute("data-track-target", i === index))
  },

  onUp(event) {
    if (!this.drag) return
    const {block, clipId, grabOffsetMs, trackEl, originX, originY} = this.drag
    this.drag = null

    block.style.transform = ""
    block.classList.remove("z-20", "opacity-80")

    const tracks = this.tracks()
    tracks.forEach((track) => track.removeAttribute("data-track-target"))

    // A press that barely moved is a click, not a drag: it selects the clip so
    // copy, paste, and delete have something to act on. Without this, clips
    // could be moved but never picked.
    if (isClick(event.clientX - originX, event.clientY - originY)) {
      // This does NOT reach StatusLive directly, even though the selection
      // lives there: a hook's pushEvent resolves against the phx-target on the
      // hook's own element, and this container carries phx-target={@myself}.
      // The component takes `select_clip` and forwards it up — see its
      // handle_event for the bug this once caused.
      this.pushEvent("select_clip", {id: clipId})
      return
    }

    const index = trackIndexAt(event.clientY, tracks.map((t) => t.getBoundingClientRect()))
    const targetTrack = index >= 0 ? tracks[index] : trackEl

    // pushEventTo for the move: the arrangement lives in the live_component,
    // and naming the element makes that routing explicit instead of leaning on
    // the same phx-target resolution the comment above describes.
    this.pushEventTo(this.el, "move_clip", {
      clip_id: clipId,
      track_id: targetTrack.dataset.trackId,
      start_ms: dropStartMs(this.msAtX(event.clientX, targetTrack), grabOffsetMs),
    })
  },
}
