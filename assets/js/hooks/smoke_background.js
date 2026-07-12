// Smoke background hook — drives the WebGPU smoke field behind the homepage
// chat. Pure ambient atmosphere: no content, no reveal, no lens (lifted from the
// old Humo surface loop, minus everything that made the smoke a reading
// surface). If WebGPU is unavailable the canvas simply stays blank; the chat
// over it is unaffected.
import {createSmoke, SmokeGpuError, fetchShaderSource} from "../smoke/smoke.js"
import {packUniforms, NEUTRAL_EXPRESSION} from "../smoke/params.js"
import {SHADER_PALETTES, colorsForUniform} from "../smoke/palettes.js"

// Resolve the palette for an element: custom colors (data-colors) when
// data-custom="true", else the shader's built-in default. Falls back to the
// default on any malformed input.
export function resolvePalette(el) {
  const shader = el.getAttribute("data-shader") || "smoke"
  const fallback = SHADER_PALETTES[shader] || SHADER_PALETTES.smoke
  if (el.getAttribute("data-custom") !== "true") return colorsForUniform(fallback)
  const hexes = (el.getAttribute("data-colors") || "").split(",").map((s) => s.trim())
  const ok = hexes.length === 3 && hexes.every(Boolean)
  return colorsForUniform(ok ? hexes : fallback)
}

// A subtler post treatment than the old foreground look, so it reads as a
// backdrop and never fights the text over it: no glow, faint grain/scanlines,
// stronger edge vignette.
const BG_POST = {glow: 0.0, grain: 0.03, scanline: 0.06, vignette: 0.5}

export const SmokeBackground = {
  mounted() {
    this.canvas = this.el.querySelector("[data-smoke-canvas]")
    this.shader = this.el.getAttribute("data-shader") || "smoke"
    this.raf = null
    this.smoke = null
    this.destroyed_ = false
    this.expr = {...NEUTRAL_EXPRESSION}
    this.reduceMotion =
      !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches)
    this.post = {...BG_POST}
    if (this.reduceMotion) this.post.grain = 0
    // Palette (custom or the shader's default); the div remounts on any change.
    this.colors = resolvePalette(this.el)
    this.intensity = 0.85
    this.uniforms = packUniforms({width: 0, height: 0, timeSec: 0, intensity: this.intensity, reveal: 0})

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
    // Custom shader (data-shader-source): fetch its raw WGSL and let createSmoke
    // prepend the prelude + compile it live. Built-ins have no source URL.
    let source = null
    const sourceUrl = this.el.getAttribute("data-shader-source")
    if (sourceUrl) {
      source = await fetchShaderSource(sourceUrl)
      if (this.destroyed_) return
      if (source == null) {
        this.el.setAttribute("data-smoke", "unavailable:shader-fetch-failed")
        return
      }
    }

    try {
      this.smoke = await createSmoke(this.canvas, {shader: this.shader, source})
    } catch (e) {
      const reason = e instanceof SmokeGpuError ? e.reason : e.message
      this.el.setAttribute("data-smoke", "unavailable:" + reason)
      return
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

    // Subtle churn while the agent is running — read the chat panel's existing
    // data-running (LiveView keeps it current; no new event needed).
    const running =
      document.getElementById("home-agent-chat")?.getAttribute("data-running") === "true"
    const target = running ? 1.15 : 0.85
    this.intensity += (target - this.intensity) * 0.03

    packUniforms(
      {
        width: this.canvas.width,
        height: this.canvas.height,
        timeSec: now / 1000,
        intensity: this.intensity,
        reveal: 0,
        expression: this.expr,
        post: this.post,
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
    // Per-pixel-heavy shaders render below full retina and capped, since they're
    // ambient backgrounds behind a blurred panel. Mandelbrot (iteration loop)
    // can go quite low; Weather needs more pixels so its fine rain/snow stay
    // crisp, so it caps higher and closer to retina.
    const cfg =
      this.shader === "weather"
        ? {density: dpr * 0.85, maxDim: 1400}
        : this.shader === "mandel"
          ? {density: 0.6, maxDim: 820}
          : {density: dpr, maxDim: Infinity}
    const {density, maxDim} = cfg

    let w = Math.max(1, Math.round(rect.width * density))
    let h = Math.max(1, Math.round(rect.height * density))
    const over = Math.max(w, h) / maxDim
    if (over > 1) {
      w = Math.max(1, Math.round(w / over))
      h = Math.max(1, Math.round(h / over))
    }

    if (w !== this.canvas.width || h !== this.canvas.height) {
      this.canvas.width = w
      this.canvas.height = h
      this.smoke?.resize()
    }
  },
}
