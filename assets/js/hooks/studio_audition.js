// The Studio's transport: hear the open audio WITHOUT rendering it — press
// Play and the timeline sounds, the way Pro Tools plays its session on the
// spacebar. Render stays the bounce, for when the mix is worth a file.
//
// The DOM is the score. The server renders which tracks are audible
// (data-audible carries StudioAudio.audible?/2, so mute/solo semantics are
// never recomputed here) and where every clip starts; this hook fetches each
// source from its same-origin route, decodes it, and schedules the buffers at
// the declared offsets on one AudioContext clock. No blob: URLs (CSP), no
// temp files, no second mixdown implementation — WebAudio sums the same
// samples the render sums; the render saturates into int16 while the DAC
// clips floats, a difference only audible in a mix already clipping.
//
// The hook lives on the Play button, keyed by the open audio, so switching
// audios remounts it: destroyed() closes the context, and a stale score can
// never keep sounding over a new arrangement.
import {auditionPlan, planEndMs, playheadRatio} from "../lib/audition.js"

export const StudioAudition = {
  mounted() {
    this.playing = false
    // Decoded buffers cache across plays — an AudioBuffer is a PCM container,
    // not bound to the context that decoded it. Sources are files on disk;
    // within one open audio they do not change under us.
    this.buffers = new Map()
    this.onClick = this.onClick.bind(this)
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.stop()
    this.el.removeEventListener("click", this.onClick)
  },

  // Any LiveView patch to the button (a mute toggled, a clip added) restores
  // the server's label; reassert the transport state on top of it.
  updated() {
    this.paint()
  },

  arranger() {
    return document.getElementById(this.el.dataset.arranger)
  },

  score() {
    const root = this.arranger()
    if (!root) return []

    return Array.from(root.querySelectorAll("[data-track]")).map((region) => ({
      audible: region.dataset.audible === "true",
      clips: Array.from(region.querySelectorAll("[data-clip]")).map((clip) => ({
        src: clip.dataset.src,
        startMs: parseFloat(clip.dataset.startMs) || 0,
      })),
    }))
  },

  async onClick() {
    if (this.playing) return this.stop()

    const plays = auditionPlan(this.score())
    if (plays.length === 0) return this.flash("nothing audible")

    try {
      await this.start(plays)
    } catch (_error) {
      this.stop()
      this.flash("couldn't decode")
    }
  },

  async start(plays) {
    this.playing = true
    this.paint()

    // A fresh context per performance: closing it on stop is what actually
    // silences every scheduled buffer at once, with no bookkeeping of nodes.
    this.ctx = new AudioContext()

    const srcs = [...new Set(plays.map((play) => play.src))]
    await Promise.all(srcs.map((src) => this.decode(src)))
    if (!this.playing) return // stopped while decoding

    const durations = new Map(srcs.map((src) => [src, this.buffers.get(src).duration * 1000]))

    // A small lead-in so every start lands in the future — scheduling at
    // exactly currentTime makes the first clip's onset ragged.
    const t0 = this.ctx.currentTime + 0.05

    for (const play of plays) {
      const node = this.ctx.createBufferSource()
      node.buffer = this.buffers.get(play.src)
      node.connect(this.ctx.destination)
      node.start(t0 + play.startMs / 1000)
    }

    this.t0 = t0
    this.endMs = planEndMs(plays, durations)
    this.tick()
  },

  async decode(src) {
    if (this.buffers.has(src)) return this.buffers.get(src)

    const response = await fetch(src)
    if (!response.ok) throw new Error(`${src}: ${response.status}`)

    const buffer = await this.ctx.decodeAudioData(await response.arrayBuffer())
    this.buffers.set(src, buffer)
    return buffer
  },

  tick() {
    if (!this.playing) return

    const elapsedMs = (this.ctx.currentTime - this.t0) * 1000
    this.movePlayhead(playheadRatio(elapsedMs, this.endMs))

    if (elapsedMs >= this.endMs) return this.stop()
    this.raf = requestAnimationFrame(() => this.tick())
  },

  // The playhead is one absolutely-positioned line spanning the track rows.
  // Its x comes from a REGION's rect, not the container's, because the
  // control clusters sit to the left and time zero is where the clips start.
  // Class and position are re-asserted every frame, so a LiveView patch that
  // re-hides it mid-play loses within 16ms.
  movePlayhead(ratio) {
    const root = this.arranger()
    const head = root && root.querySelector("[data-playhead]")
    if (!head) return

    const regions = root.querySelectorAll("[data-track]")
    if (regions.length === 0) return

    const rootRect = root.getBoundingClientRect()
    const first = regions[0].getBoundingClientRect()
    const last = regions[regions.length - 1].getBoundingClientRect()

    head.classList.remove("hidden")
    head.style.top = `${first.top - rootRect.top}px`
    head.style.height = `${last.bottom - first.top}px`
    head.style.left = `${first.left - rootRect.left + ratio * first.width}px`
  },

  stop() {
    this.playing = false
    if (this.raf) cancelAnimationFrame(this.raf)

    if (this.ctx) {
      this.ctx.close().catch(() => {})
      this.ctx = null
    }

    const root = this.arranger()
    const head = root && root.querySelector("[data-playhead]")
    if (head) head.classList.add("hidden")

    this.paint()
  },

  paint() {
    this.el.textContent = this.playing ? "■ Stop" : "▶ Play"
  },

  flash(message) {
    this.el.textContent = `✕ ${message}`
    setTimeout(() => this.paint(), 1500)
  },
}
