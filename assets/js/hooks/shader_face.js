// Shaderface hook — renders one contact's face in the Contacts panel. Runs the
// built-in `face` shader (or a custom face fetched from /shaders/<name>) through
// createSmoke, with the contact's seed carried on the prelude's lens channel
// (u.lens.x) — free for non-background shaders, and the documented seed contract
// for custom faces. Palette comes from data-colors (hazard face on charcoal by
// default). WebGPU missing → canvas stays blank behind the text details.
import {createSmoke, fetchShaderSource} from "../smoke/smoke.js"
import {packUniforms, NEUTRAL_EXPRESSION} from "../smoke/params.js"
import {colorsForUniform} from "../smoke/palettes.js"

const FACE_POST = {glow: 0.0, grain: 0.04, scanline: 0.1, vignette: 0.55}
const DEFAULT_FACE_COLORS = ["#141210", "#ff4d1c", "#f4f1ea"]

export const ShaderFace = {
  mounted() {
    this.canvas = this.el.querySelector("[data-face-canvas]")
    this.seed = parseFloat(this.el.getAttribute("data-seed") || "0")
    this.raf = null
    this.smoke = null
    this.destroyed_ = false
    this.reduceMotion =
      !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches)

    const hexes = (this.el.getAttribute("data-colors") || "").split(",").map((s) => s.trim())
    this.colors = colorsForUniform(hexes.length === 3 && hexes.every(Boolean) ? hexes : DEFAULT_FACE_COLORS)
    this.uniforms = packUniforms({width: 0, height: 0, timeSec: 0, intensity: 0.9, reveal: 0})

    this.onVisibility = () => {
      if (!document.hidden && this.smoke && this.raf == null) {
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
    this.smoke?.destroy()
  },

  async boot() {
    // Custom face (data-shader-source): raw WGSL from /shaders/<name>, prelude
    // prepended + compiled live. Falls back to the built-in face on any failure
    // rather than showing nothing — a bad custom face never blanks a contact.
    let source = null
    const sourceUrl = this.el.getAttribute("data-shader-source")
    if (sourceUrl) {
      source = await fetchShaderSource(sourceUrl)
      if (this.destroyed_) return
    }

    try {
      this.smoke = await createSmoke(this.canvas, {shader: "face", source})
    } catch (_e) {
      if (source) {
        // Custom face failed to compile — retry with the built-in.
        try {
          this.smoke = await createSmoke(this.canvas, {shader: "face"})
        } catch (_e2) {
          this.el.setAttribute("data-face", "unavailable")
          return
        }
      } else {
        this.el.setAttribute("data-face", "unavailable")
        return
      }
    }
    if (this.destroyed_) return this.smoke.destroy()

    this.smoke.lost.then(() => {
      if (this.destroyed_) return
      this.smoke = null
      if (this.raf != null) cancelAnimationFrame(this.raf)
      this.raf = null
    })

    this.raf = requestAnimationFrame(this.frame)
  },

  frame(now) {
    this.raf = null
    if (!this.smoke || this.destroyed_) return

    packUniforms(
      {
        width: this.canvas.width,
        height: this.canvas.height,
        timeSec: now / 1000,
        intensity: 0.9,
        reveal: 0,
        // The seed rides the lens channel — see the contract in face.wgsl.js.
        lens: {x: this.seed, y: 0, radius: 0, strength: 0},
        expression: NEUTRAL_EXPRESSION,
        post: FACE_POST,
        motion: this.reduceMotion ? 0.3 : 1,
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
