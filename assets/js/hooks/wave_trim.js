// Drag-to-select over the Studio's waveform (SOUND_STUDIO_ROADMAP Phase 3).
//
// A DOM overlay, deliberately, not shader work: `clipwave.js` renders an
// envelope texture and has no notion of a cursor or a selection, and the
// roadmap's own risk note said to try this first. Four absolutely-positioned
// divs (two shades, two edges) cost nothing and are styleable in CSS.
//
// Ownership: this hook owns the overlay's inline styles and nothing else. The
// overlay sits under `phx-update="ignore"` so LiveView never patches it out
// from under us, which means server→client changes (Reset, a new source) must
// arrive as events, not as re-rendered markup. Two of them:
//
//   studio:trim    — set or clear the selection (Reset, or a fresh file)
//   studio:preview — play just the selection
//
// The audio element is found by id rather than passed in: it is server-rendered
// beneath us and there is exactly one at a time.

// The geometry lives in a bun-tested lib module (same reason as `dtmf.js`):
// this arithmetic decides what gets cut out of someone's audio.
import {msAtRatio, selection, isMeaningful, overlay} from "../lib/trim.js"

export const WaveTrim = {
  mounted() {
    this.shadeL = this.el.querySelector("[data-trim-shade-l]")
    this.shadeR = this.el.querySelector("[data-trim-shade-r]")
    this.edgeA = this.el.querySelector("[data-trim-edge-a]")
    this.edgeB = this.el.querySelector("[data-trim-edge-b]")

    this.from = null
    this.to = null
    this.anchor = null
    this.previewTimer = null

    this.onDown = this.onDown.bind(this)
    this.onMove = this.onMove.bind(this)
    this.onUp = this.onUp.bind(this)

    this.el.addEventListener("pointerdown", this.onDown)
    // Move and up go on the window: a drag that leaves the waveform (past
    // either end, which is exactly how you select "to the end") must keep
    // tracking rather than freezing where the cursor exited.
    window.addEventListener("pointermove", this.onMove)
    window.addEventListener("pointerup", this.onUp)

    this.handleEvent("studio:trim", ({from_ms, to_ms}) => {
      this.from = from_ms
      this.to = to_ms
      this.draw()
    })

    this.handleEvent("studio:preview", ({from_ms, to_ms}) => this.preview(from_ms, to_ms))

    this.restore()
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onDown)
    window.removeEventListener("pointermove", this.onMove)
    window.removeEventListener("pointerup", this.onUp)
    this.clearPreviewTimer()
  },

  duration() {
    const ms = parseFloat(this.el.dataset.durationMs)
    return Number.isFinite(ms) && ms > 0 ? ms : 0
  },

  // The server may already hold a selection for this file — a tab switch
  // remounts the hook, and the roadmap's whole point is that the edit survives.
  restore() {
    const from = parseFloat(this.el.dataset.fromMs)
    const to = parseFloat(this.el.dataset.toMs)
    if (Number.isFinite(from) && Number.isFinite(to)) {
      this.from = from
      this.to = to
    }
    this.draw()
  },

  msAt(clientX) {
    const rect = this.el.getBoundingClientRect()
    if (rect.width <= 0) return 0
    return msAtRatio((clientX - rect.left) / rect.width, this.duration())
  },

  onDown(event) {
    if (this.duration() <= 0 || event.button !== 0) return
    event.preventDefault()
    this.anchor = this.msAt(event.clientX)
    this.from = this.anchor
    this.to = this.anchor
    this.draw()
  },

  onMove(event) {
    if (this.anchor == null) return
    const {from, to} = selection(this.anchor, this.msAt(event.clientX))
    this.from = from
    this.to = to
    this.draw()
  },

  onUp() {
    if (this.anchor == null) return
    this.anchor = null

    if (isMeaningful({from: this.from, to: this.to})) {
      this.pushEvent("trim_select", {from_ms: this.from, to_ms: this.to})
    } else {
      this.from = null
      this.to = null
      this.draw()
      this.pushEvent("trim_clear", {})
    }
  },

  draw() {
    const total = this.duration()
    const active = total > 0 && this.from != null && this.to != null
    const box = overlay({from: this.from || 0, to: this.to || 0}, total)

    this.shadeL.style.width = active ? `${box.left}%` : "0%"
    this.shadeR.style.width = active ? `${box.right}%` : "0%"
    // Parked off-canvas rather than at 0% when idle: an edge marker sitting on
    // the left rail reads as a selection of zero length, not as no selection.
    this.edgeA.style.left = active ? `${box.edgeA}%` : "-10px"
    this.edgeB.style.left = active ? `${box.edgeB}%` : "-10px"
    this.el.toggleAttribute("data-trim-active", active)
  },

  // Preview plays the real file and simply stops early. No blob, no temp file,
  // no server round trip — and no CSP surface, since the element's src is the
  // same route it already had.
  preview(fromMs, toMs) {
    const audio = document.getElementById("studio-audio")
    if (!audio) return

    this.clearPreviewTimer()
    audio.currentTime = fromMs / 1000

    const stop = () => {
      audio.pause()
      this.previewTimer = null
    }

    const play = audio.play()
    // Autoplay policy can refuse this before any user gesture; report by doing
    // nothing rather than scheduling a stop for audio that never started.
    if (play && typeof play.catch === "function") play.catch(() => {})

    this.previewTimer = window.setTimeout(stop, Math.max(0, toMs - fromMs))
  },

  clearPreviewTimer() {
    if (this.previewTimer != null) {
      window.clearTimeout(this.previewTimer)
      this.previewTimer = null
    }
  },
}
