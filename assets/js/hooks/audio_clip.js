// Audio clip hook — one DAW-style region in the Phone tab's rack. Fetches the
// clip's actual audio (data-src), decodes it to an envelope, and renders the
// real waveform with the clipwave WGSL shader (data-color-a hot / data-color-b
// fill). Anything fails — no WebGPU, fetch, decode — and the clip reveals its
// static CSS fallback bars; the labels around the canvas never depend on GPU.
import {createClipWave, decodePeaks} from "../audio/clipwave.js"

export const AudioClip = {
  mounted() {
    this.canvas = this.el.querySelector("[data-clip-canvas]")
    this.wave = null
    this.raf = null
    this.destroyed_ = false

    this.onVisibility = () => {
      if (!document.hidden && this.wave && this.raf == null) {
        this.raf = requestAnimationFrame(this.frame)
      }
    }
    document.addEventListener("visibilitychange", this.onVisibility)

    this.observer = new ResizeObserver(() => this.fitCanvas())
    this.observer.observe(this.el)
    this.fitCanvas()

    this.frame = this.frame.bind(this)
    this.boot()
  },

  destroyed() {
    this.destroyed_ = true
    if (this.raf != null) cancelAnimationFrame(this.raf)
    document.removeEventListener("visibilitychange", this.onVisibility)
    this.observer?.disconnect()
    this.wave?.destroy()
  },

  async boot() {
    try {
      const res = await fetch(this.el.getAttribute("data-src"))
      if (!res.ok) throw new Error("fetch " + res.status)
      const peaks = await decodePeaks(await res.arrayBuffer())
      if (this.destroyed_) return
      if (!peaks) throw new Error("decode failed")

      this.wave = await createClipWave(this.canvas, {
        peaks,
        colorA: this.el.getAttribute("data-color-a"),
        colorB: this.el.getAttribute("data-color-b"),
      })
      if (!this.wave) throw new Error("webgpu unavailable")
    } catch (e) {
      this.el.setAttribute("data-clip", "unavailable:" + e.message)
      this.el.querySelector("[data-clip-fallback]")?.classList.remove("hidden")
      return
    }
    if (this.destroyed_) return this.wave.destroy()

    this.wave.lost.then(() => {
      if (this.raf != null) cancelAnimationFrame(this.raf)
      this.raf = null
      this.wave = null
    })

    this.raf = requestAnimationFrame(this.frame)
  },

  frame(now) {
    this.raf = null
    if (!this.wave || this.destroyed_) return
    this.wave.render(now / 1000)
    if (!document.hidden) this.raf = requestAnimationFrame(this.frame)
  },

  fitCanvas() {
    const rect = this.el.getBoundingClientRect()
    const dpr = Math.min(window.devicePixelRatio || 1, 1.5)
    const w = Math.max(1, Math.round(rect.width * dpr))
    const h = Math.max(1, Math.round(rect.height * dpr))
    if (w !== this.canvas.width || h !== this.canvas.height) {
      this.canvas.width = w
      this.canvas.height = h
      this.wave?.resize()
    }
  },
}
