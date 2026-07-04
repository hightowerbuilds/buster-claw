// A small live preview of the selected homepage shader with the chosen colors.
// The container is keyed by shader + custom (so switching either remounts it),
// and while custom is on it reads the color <input> values every frame — so
// dragging a picker updates the preview instantly, no server round-trip.
import {createSmoke, SmokeGpuError} from "../smoke/smoke.js"
import {packUniforms, NEUTRAL_EXPRESSION} from "../smoke/params.js"
import {SHADER_PALETTES, colorsForUniform} from "../smoke/palettes.js"

const PREVIEW_POST = {glow: 0, grain: 0.03, scanline: 0.08, vignette: 0.4}

export const ShaderPreview = {
  mounted() {
    this.canvas = this.el.querySelector("canvas")
    this.shader = this.el.getAttribute("data-shader") || "smoke"
    this.custom = this.el.getAttribute("data-custom") === "true"
    this.destroyed_ = false
    this.raf = null
    this.expr = {...NEUTRAL_EXPRESSION}
    this.uniforms = packUniforms({width: 0, height: 0, timeSec: 0, intensity: 1, reveal: 0})
    this.fit()
    this.frame = this.frame.bind(this)
    this.boot()
  },

  destroyed() {
    this.destroyed_ = true
    if (this.raf != null) cancelAnimationFrame(this.raf)
    this.smoke?.destroy()
  },

  async boot() {
    try {
      this.smoke = await createSmoke(this.canvas, {shader: this.shader})
    } catch (e) {
      const reason = e instanceof SmokeGpuError ? e.reason : e.message
      this.el.setAttribute("data-preview", "unavailable:" + reason)
      return
    }
    if (this.destroyed_) return this.smoke.destroy()
    this.smoke.lost.then(() => {
      this.smoke = null
      if (this.raf != null) cancelAnimationFrame(this.raf)
      this.raf = null
    })
    this.raf = requestAnimationFrame(this.frame)
  },

  readColors() {
    const fallback = SHADER_PALETTES[this.shader] || SHADER_PALETTES.smoke
    if (!this.custom) return colorsForUniform(fallback)
    const hexes = [1, 2, 3].map((i) => document.getElementById("home-color-" + i)?.value)
    return colorsForUniform(hexes.every(Boolean) ? hexes : fallback)
  },

  frame(now) {
    this.raf = null
    if (!this.smoke || this.destroyed_) return
    this.fit()
    packUniforms(
      {
        width: this.canvas.width,
        height: this.canvas.height,
        timeSec: now / 1000,
        intensity: 1.0,
        reveal: 0,
        expression: this.expr,
        post: PREVIEW_POST,
        motion: 1,
        colors: this.readColors(),
      },
      this.uniforms
    )
    this.smoke.render({uniforms: this.uniforms, contentDirty: false})
    this.raf = requestAnimationFrame(this.frame)
  },

  fit() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    const rect = this.el.getBoundingClientRect()
    const w = Math.max(1, Math.round(rect.width * dpr))
    const h = Math.max(1, Math.round(rect.height * dpr))
    if (w !== this.canvas.width || h !== this.canvas.height) {
      this.canvas.width = w
      this.canvas.height = h
      this.smoke?.resize()
    }
  },
}
