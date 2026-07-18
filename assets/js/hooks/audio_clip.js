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
    // The shimmer only needs to run for clips actually in the viewport — a
    // 200-row rack must not run 200 render loops. Off-screen clips park until
    // the IntersectionObserver scrolls them back in.
    this.visible = false

    this.frame = this.frame.bind(this)

    this.onVisibility = () => this.startLoop()
    document.addEventListener("visibilitychange", this.onVisibility)

    this.intersection = new IntersectionObserver((entries) => {
      this.visible = entries[entries.length - 1].isIntersecting
      if (this.visible) this.startLoop()
      else this.stopLoop()
    })
    this.intersection.observe(this.el)

    this.observer = new ResizeObserver(() => this.fitCanvas())
    this.observer.observe(this.el)
    this.fitCanvas()

    this.boot()
  },

  destroyed() {
    this.destroyed_ = true
    this.stopLoop()
    document.removeEventListener("visibilitychange", this.onVisibility)
    this.intersection?.disconnect()
    this.observer?.disconnect()
    this.wave?.destroy()
  },

  startLoop() {
    if (this.wave && this.raf == null && this.visible && !document.hidden) {
      this.raf = requestAnimationFrame(this.frame)
    }
  },

  stopLoop() {
    if (this.raf != null) {
      cancelAnimationFrame(this.raf)
      this.raf = null
    }
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
      this.stopLoop()
      this.wave = null
    })

    this.startLoop()
  },

  frame(now) {
    this.raf = null
    if (!this.wave || this.destroyed_) return
    this.wave.render(now / 1000)
    if (!document.hidden && this.visible) this.raf = requestAnimationFrame(this.frame)
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
