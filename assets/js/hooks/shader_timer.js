// ShaderTimer — the live seven-segment countdown for the Notify widget. It owns
// the target moment locally (data-fire-at, unix seconds) and, each frame,
// computes the remaining time and feeds it to the `sevenseg` shader on the
// prelude's free lens channel (u.lens.x). That keeps the countdown smooth with
// no server round-trips; the server only supplies fire-at, and re-keys the
// element (id carries fire-at) when the soonest notification changes, remounting
// this hook with a new target.
//
// Progressive enhancement: a plain-text MM:SS node updates alongside the canvas
// and shows through when WebGPU is unavailable (the canvas stays blank).
import {createSmoke} from "../smoke/smoke.js"
import {packUniforms} from "../smoke/params.js"
import {colorsForUniform} from "../smoke/palettes.js"

// a = unlit background, b = colon accent (hazard), c = lit segments (cream).
const DEFAULT_TIMER_COLORS = ["#121212", "#ff4d1c", "#f4f1ea"]
const TIMER_POST = {glow: 0.0, grain: 0.0, scanline: 0.06, vignette: 0.2}

function pad2(n) {
  return n < 10 ? `0${n}` : `${n}`
}

function formatRemaining(seconds) {
  const t = Math.max(0, Math.floor(seconds))
  if (t < 3600) return `${pad2(Math.floor(t / 60))}:${pad2(t % 60)}`
  return `${pad2(Math.min(99, Math.floor(t / 3600)))}:${pad2(Math.floor((t % 3600) / 60))}`
}

export const ShaderTimer = {
  mounted() {
    this.canvas = this.el.querySelector("[data-timer-canvas]")
    this.text = this.el.querySelector("[data-timer-text]")
    this.targetMs = (parseInt(this.el.getAttribute("data-fire-at"), 10) || 0) * 1000
    this.raf = null
    this.interval = null
    this.smoke = null
    this.destroyed_ = false
    this.lastSecond = null

    const hexes = (this.el.getAttribute("data-colors") || "").split(",").map((s) => s.trim())
    this.colors = colorsForUniform(
      hexes.length === 3 && hexes.every(Boolean) ? hexes : DEFAULT_TIMER_COLORS
    )
    this.uniforms = packUniforms({width: 0, height: 0, timeSec: 0, intensity: 1, reveal: 0})

    this.frame = this.frame.bind(this)
    this.tickText = this.tickText.bind(this)

    this.onVisibility = () => {
      if (!document.hidden && this.smoke && this.raf == null) {
        this.raf = requestAnimationFrame(this.frame)
      }
    }
    document.addEventListener("visibilitychange", this.onVisibility)

    this.observer = new ResizeObserver(() => this.fitCanvas())
    this.observer.observe(this.el)
    this.fitCanvas()
    this.tickText()

    this.boot()
  },

  destroyed() {
    this.destroyed_ = true
    if (this.raf != null) cancelAnimationFrame(this.raf)
    if (this.interval != null) clearInterval(this.interval)
    document.removeEventListener("visibilitychange", this.onVisibility)
    this.observer?.disconnect()
    this.smoke?.destroy()
  },

  async boot() {
    try {
      this.smoke = await createSmoke(this.canvas, {shader: "sevenseg"})
    } catch (_e) {
      // No WebGPU (or compile failure) — fall back to the text node, updated once
      // a second. The canvas stays blank behind it.
      if (this.destroyed_) return
      this.showText(true)
      this.el.setAttribute("data-timer", "text")
      this.interval = setInterval(this.tickText, 1000)
      return
    }
    if (this.destroyed_) return this.smoke.destroy()

    this.smoke.lost.then(() => {
      if (this.destroyed_) return
      this.smoke = null
      if (this.raf != null) cancelAnimationFrame(this.raf)
      this.raf = null
      // Keep time visible after a device loss.
      this.showText(true)
      this.el.setAttribute("data-timer", "text")
      if (this.interval == null) this.interval = setInterval(this.tickText, 1000)
    })

    // Shader owns the display; the digits are the readout, so hide the text.
    this.showText(false)
    this.el.setAttribute("data-timer", "shader")
    this.raf = requestAnimationFrame(this.frame)
  },

  showText(visible) {
    if (this.text) this.text.style.visibility = visible ? "" : "hidden"
  },

  remainingSeconds() {
    return Math.max(0, (this.targetMs - Date.now()) / 1000)
  },

  // Keep the text fallback current, but only re-write the DOM when the displayed
  // second actually changes.
  tickText() {
    if (this.destroyed_ || !this.text) return
    const label = formatRemaining(this.remainingSeconds())
    if (label !== this.lastSecond) {
      this.text.textContent = label
      this.lastSecond = label
    }
  },

  frame(now) {
    this.raf = null
    if (!this.smoke || this.destroyed_) return

    const remaining = this.remainingSeconds()
    this.tickText()

    packUniforms(
      {
        width: this.canvas.width,
        height: this.canvas.height,
        timeSec: now / 1000,
        intensity: 1,
        reveal: 0,
        // Remaining seconds ride the free lens channel — see sevenseg.wgsl.js.
        lens: {x: remaining, y: 0, radius: 0, strength: 0},
        post: TIMER_POST,
        colors: this.colors,
      },
      this.uniforms
    )
    this.smoke.render({uniforms: this.uniforms, contentDirty: false})

    if (!document.hidden) this.raf = requestAnimationFrame(this.frame)
  },

  fitCanvas() {
    const rect = this.el.getBoundingClientRect()
    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    const w = Math.max(1, Math.round(rect.width * dpr))
    const h = Math.max(1, Math.round(rect.height * dpr))
    if (w !== this.canvas.width || h !== this.canvas.height) {
      this.canvas.width = w
      this.canvas.height = h
      this.smoke?.resize()
    }
  },
}
