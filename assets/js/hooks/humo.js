// Humo surface hooks. HumoSurface owns the DOM side of the screen: canvas
// backing size at real devicePixelRatio, the rAF loop with a visibility pause,
// and the conversation-state machine driven by the server — HumoLive
// push_events `humo:phase` (thinking/settled/idle) and `humo:text` (an assistant
// block to read out).
//
// The screen is the primary reading surface: replies READ OUT — words appear at
// a cadence, fill the page, and when the next word wouldn't fit the page
// dissolves back into smoke to make room for the next one. The final page
// settles and holds. All GPU work lives in humo/screen.js (one pipeline);
// content is authored on Canvas2D by the presenters (humo/presenters/*); all
// pure math (wrap, page-fit, reveal clocks, uniform mapping) in humo/params.js +
// humo/text_layout.js, where it is bun-tested.
import {createScreen, HumoGpuError} from "../humo/screen.js"
import {
  packUniforms,
  pageReveal,
  mapChatState,
  styleFromSpec,
  easeExpression,
  NEUTRAL_EXPRESSION,
} from "../humo/params.js"
import {createChatPresenter} from "../humo/presenters/chat.js"

// Readout cadence: blocks arrive whole (stream-json is block-level), so this
// is a presentation clock — how fast the screen "speaks".
const MS_PER_WORD = 90
const CONDENSE_MS = 800
const DISSOLVE_MS = 700

export const HumoSurface = {
  mounted() {
    this.canvas = this.el.querySelector("[data-humo-canvas]")
    this.status = this.el.querySelector("[data-humo-status]")
    this.raf = null
    this.screen = null
    this.destroyed_ = false

    // The chat presenter authors the conversation onto its own Canvas2D, which
    // feeds the screen's content texture.
    this.content = createChatPresenter()

    // Conversation state, server-driven. `hasText` keeps the last page legible
    // while idle.
    this.chat = {phase: "idle", hasText: false}
    // Active readout: the words still being spoken into the screen.
    this.readout = null

    // Expression (mood + render mode), server-driven. Each reply's style eases
    // from neutral: a new turn resets the target so styling is per-reply, and a
    // `humo-style` block in that reply overrides it.
    this.expr = {...NEUTRAL_EXPRESSION}
    this.exprTarget = {...NEUTRAL_EXPRESSION}
    this.handleEvent("humo:style", ({spec}) => {
      this.exprTarget = styleFromSpec(spec)
    })

    // Cleared conversation: drop any readout, blank the content texture so
    // nothing lingers under the fog, and settle to empty drifting smoke.
    this.handleEvent("humo:reset", () => {
      this.readout = null
      this.content.clear()
      this.exprTarget = {...NEUTRAL_EXPRESSION}
      this.chat = {phase: "idle", hasText: false}
    })

    this.handleEvent("humo:phase", ({phase}) => {
      if (phase === "thinking") {
        // New turn: the old page dissolves under the churn (reveal → 0), and
        // the style eases back to neutral unless this reply sets one.
        this.readout = null
        this.chat.phase = "thinking"
        this.exprTarget = {...NEUTRAL_EXPRESSION}
      } else if (this.readout) {
        // A readout in progress finishes speaking before settling/idling.
      } else if (phase === "idle" && this.chat.hasText) {
        this.chat.phase = "settled"
      } else {
        this.chat.phase = phase
      }
    })

    this.handleEvent("humo:text", ({text}) => {
      const words = text.split(/\s+/).filter(Boolean)
      if (words.length === 0) return
      if (this.readout) {
        // Another block in the same turn: queue its words onto the readout.
        this.readout.words.push(...words)
      } else {
        const now = performance.now()
        this.content.clear()
        this.readout = {
          words,
          idx: 0,
          page: [],
          pagePhase: "filling",
          phaseStartedAt: now,
          nextWordAt: now,
        }
        this.chat = {phase: "reading", hasText: true}
      }
    })

    this.uniforms = packUniforms({width: 0, height: 0, timeSec: 0, intensity: 1, reveal: 0})

    // The still lens: hovering holds the smoke under a soft circle (frozen
    // clock in-shader) with chromatic fringing at the rim. Strength eases in
    // and out; the freeze timestamp is captured at hover-start so the held
    // smoke stays perfectly still however long you look.
    this.lens = {x: 0.5, y: 0.5, radius: 0.16, strength: 0, target: 0}
    this.freezeAt = 0
    this.onPointerMove = (e) => {
      const rect = this.canvas.getBoundingClientRect()
      const inside =
        e.clientX >= rect.left && e.clientX <= rect.right &&
        e.clientY >= rect.top && e.clientY <= rect.bottom
      if (inside) {
        if (this.lens.target === 0) this.freezeAt = performance.now() / 1000
        this.lens.target = 1
        this.lens.x = (e.clientX - rect.left) / rect.width
        this.lens.y = 1 - (e.clientY - rect.top) / rect.height
      } else {
        this.lens.target = 0
      }
    }
    this.onPointerLeave = () => {
      this.lens.target = 0
    }
    window.addEventListener("pointermove", this.onPointerMove)
    document.documentElement.addEventListener("pointerleave", this.onPointerLeave)

    this.onVisibility = () => {
      if (!document.hidden && this.screen && this.raf == null) {
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
    window.removeEventListener("pointermove", this.onPointerMove)
    document.documentElement.removeEventListener("pointerleave", this.onPointerLeave)
    this.observer?.disconnect()
    this.screen?.destroy()
  },

  async boot() {
    try {
      this.screen = await createScreen(this.canvas, {
        contentWidth: this.content.dims.width,
        contentHeight: this.content.dims.height,
      })
    } catch (e) {
      // No GPU → say so plainly; the DOM transcript is the real fallback,
      // so nothing is lost but the screen.
      const reason = e instanceof HumoGpuError ? e.reason : e.message
      this.setStatus("humo · gpu unavailable — " + reason)
      return
    }
    if (this.destroyed_) return this.screen.destroy()

    this.screen.lost.then((info) => {
      if (this.destroyed_) return
      this.screen = null
      if (this.raf != null) cancelAnimationFrame(this.raf)
      this.raf = null
      this.setStatus("humo · gpu lost — " + (info?.message || "device lost"))
    })

    this.frames = []
    this.lastFrameAt = performance.now()
    this.raf = requestAnimationFrame(this.frame)
  },

  frame(now) {
    this.raf = null
    if (!this.screen || this.destroyed_) return

    this.frames.push(now - this.lastFrameAt)
    if (this.frames.length > 120) this.frames.shift()
    this.lastFrameAt = now

    const state = this.readout ? this.tickReadout(now) : this.chat
    const mapped = mapChatState(state)
    // Ease the lens in/out; while fully off it costs the shader nothing.
    this.lens.strength += (this.lens.target - this.lens.strength) * 0.14
    if (this.lens.strength < 0.005 && this.lens.target === 0) this.lens.strength = 0
    // Ease the expression (mood + render mode) toward its target.
    this.expr = easeExpression(this.expr, this.exprTarget)
    packUniforms(
      {
        width: this.canvas.width,
        height: this.canvas.height,
        timeSec: now / 1000,
        intensity: mapped.intensity,
        reveal: mapped.reveal,
        freezeTime: this.freezeAt,
        lens: this.lens,
        expression: this.expr,
      },
      this.uniforms
    )
    this.screen.render({
      uniforms: this.uniforms,
      contentSource: this.content.source,
      contentDirty: this.content.dirty,
    })
    this.content.markClean()

    if (now - (this.statusAt || 0) > 500) {
      this.statusAt = now
      const avg = this.frames.reduce((a, b) => a + b, 0) / this.frames.length
      this.setStatus(
        "humo · webgpu · " + (1000 / avg).toFixed(0) + " fps · dpr " +
          (window.devicePixelRatio || 1).toFixed(2) + " · " + state.phase
      )
    }

    if (!document.hidden) this.raf = requestAnimationFrame(this.frame)
  },

  // Advance the readout: dissolve a full page away, then fill the next one
  // word by word. Returns the chat state for the uniform mapping — reading
  // rides the "streaming" mapping with the page clock as its progress.
  tickReadout(now) {
    const r = this.readout

    if (r.pagePhase === "dissolving" && now - r.phaseStartedAt >= DISSOLVE_MS) {
      r.page = []
      r.pagePhase = "filling"
      r.phaseStartedAt = now
      r.nextWordAt = now
      this.content.clear()
    }

    if (r.pagePhase === "filling") {
      let drew = false
      while (r.idx < r.words.length && now >= r.nextWordAt) {
        const candidate = r.page.concat(r.words[r.idx])
        if (!this.content.fits(candidate)) {
          // Page is full — let it dissolve to make room for the next words.
          r.pagePhase = "dissolving"
          r.phaseStartedAt = now
          break
        }
        r.page = candidate
        r.idx++
        r.nextWordAt = now + MS_PER_WORD
        drew = true
      }
      if (drew) this.content.draw(r.page)

      if (r.idx >= r.words.length && r.pagePhase === "filling") {
        // Fully spoken — the final page settles and holds.
        this.readout = null
        this.chat = {phase: "settled", hasText: true}
        return this.chat
      }
    }

    const reveal = pageReveal({
      phase: r.pagePhase,
      sincePhaseMs: now - r.phaseStartedAt,
      condenseMs: CONDENSE_MS,
      dissolveMs: DISSOLVE_MS,
    })
    return {phase: "streaming", streamProgress: reveal}
  },

  fitCanvas() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    const rect = this.el.getBoundingClientRect()
    const w = Math.max(1, Math.round(rect.width * dpr))
    const h = Math.max(1, Math.round(rect.height * dpr))
    if (w !== this.canvas.width || h !== this.canvas.height) {
      this.canvas.width = w
      this.canvas.height = h
      this.screen?.resize()
    }
  },

  setStatus(text) {
    if (this.status) this.status.textContent = text
  },
}

// Keep Humo's DOM transcript pinned to the newest message.
export const HumoTranscript = {
  mounted() {
    this.el.scrollTop = this.el.scrollHeight
  },
  updated() {
    this.el.scrollTop = this.el.scrollHeight
  },
}
