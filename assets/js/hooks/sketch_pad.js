// The Sketch Pad's canvas. The hook owns every pixel; the server is never told
// about a stroke.
//
// Same rule the note editor arrived at after two failed designs: do not build a
// parallel model beside the DOM. A sketch is pixels, and sending them to Elixir
// sixty times a second to prove it would buy nothing.
//
// Its element carries `phx-update="ignore"`, so LiveView never re-renders the
// canvas out from under us. The cost is stated on the surface itself: a reload
// loses the drawing, because there is nowhere to save it yet.

const DEFAULT_COLOR = "#F4F1EA"
const DEFAULT_SIZE = 2

// The eraser paints the panel's own ground rather than using
// `globalCompositeOperation = "destination-out"`. Destination-out would punch a
// hole through to whatever is behind the canvas, and on the homepage that is a
// live shader — so an "erased" stroke would reveal the background instead of the
// paper. Painting the ground colour is the honest version of erase for an opaque
// surface, and it is why this matches the `bg-base-200` on the wrapper.
const GROUND = () =>
  getComputedStyle(document.documentElement).getPropertyValue("--color-base-200").trim() ||
  "#1a1a1a"

export default {
  mounted() {
    this.canvas = this.el.querySelector("[data-sketch-canvas]")
    this.ctx = this.canvas.getContext("2d")
    this.color = DEFAULT_COLOR
    this.size = DEFAULT_SIZE
    this.erasing = false
    this.drawing = false

    this.resize()

    // A ResizeObserver rather than a window `resize` listener, and rather than
    // measuring per frame: the panel can change size without the window doing
    // so (the dock, a sub-tab switch), and `getBoundingClientRect()` in a draw
    // loop is the forced-layout mistake `shader_preview.js` was pulled up for.
    this.observer = new ResizeObserver(() => this.resize())
    this.observer.observe(this.el)

    this.onDown = (e) => this.start(e)
    this.onMove = (e) => this.stroke(e)
    this.onUp = () => this.stop()

    this.canvas.addEventListener("pointerdown", this.onDown)
    this.canvas.addEventListener("pointermove", this.onMove)
    // `pointerup` on the window, not the canvas: releasing outside the element
    // must still end the stroke, or the next hover draws a line the user never
    // asked for.
    window.addEventListener("pointerup", this.onUp)
    this.canvas.addEventListener("pointerleave", this.onUp)

    this.wireToolbar()
  },

  destroyed() {
    this.observer?.disconnect()
    window.removeEventListener("pointerup", this.onUp)
  },

  // Toolbar buttons live in the LiveView-rendered header, OUTSIDE this hook's
  // `phx-update="ignore"` element, so they are addressed by walking up to the
  // shared section rather than querying inside `this.el`.
  wireToolbar() {
    const root = this.el.closest("#studio-sketch") || document
    const mark = (nodes, active) =>
      nodes.forEach((n) => {
        n.classList.toggle("border-primary", n === active)
        n.classList.toggle("border-base-content/25", n !== active)
      })

    const colors = [...root.querySelectorAll("[data-sketch-color]")]
    colors.forEach((b) =>
      b.addEventListener("click", () => {
        this.color = b.dataset.sketchColor
        this.erasing = false
        mark(colors, b)
      }),
    )

    const sizes = [...root.querySelectorAll("[data-sketch-size]")]
    sizes.forEach((b) =>
      b.addEventListener("click", () => {
        this.size = parseInt(b.dataset.sketchSize, 10)
        mark(sizes, b)
      }),
    )

    root.querySelector("[data-sketch-eraser]")?.addEventListener("click", () => {
      this.erasing = true
    })

    // The click arrives only after `claw_confirm` re-dispatches it, because the
    // button carries `data-claw-confirm`. Nothing here needs to know that.
    root.querySelector("[data-sketch-clear]")?.addEventListener("click", () => this.clear())
  },

  // Size the backing store in device pixels so strokes are not blurry on a
  // retina display, then scale the context so drawing code stays in CSS pixels.
  // The existing image is re-drawn rather than dropped: a resize is not an erase.
  resize() {
    const rect = this.el.getBoundingClientRect()
    if (rect.width === 0 || rect.height === 0) return

    const dpr = window.devicePixelRatio || 1
    const w = Math.round(rect.width * dpr)
    const h = Math.round(rect.height * dpr)
    if (this.canvas.width === w && this.canvas.height === h) return

    const previous = this.canvas.width > 0 ? this.canvas : null
    const carried = previous && document.createElement("canvas")
    if (carried) {
      carried.width = this.canvas.width
      carried.height = this.canvas.height
      carried.getContext("2d").drawImage(this.canvas, 0, 0)
    }

    this.canvas.width = w
    this.canvas.height = h
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    this.ctx.lineCap = "round"
    this.ctx.lineJoin = "round"

    if (carried) this.ctx.drawImage(carried, 0, 0, rect.width, rect.height)
  },

  point(e) {
    const rect = this.canvas.getBoundingClientRect()
    return {x: e.clientX - rect.left, y: e.clientY - rect.top}
  },

  start(e) {
    this.drawing = true
    this.canvas.setPointerCapture?.(e.pointerId)
    const p = this.point(e)
    this.ctx.beginPath()
    this.ctx.moveTo(p.x, p.y)
    // A tap with no movement should leave a dot rather than nothing.
    this.stroke(e)
  },

  stroke(e) {
    if (!this.drawing) return
    const p = this.point(e)
    this.ctx.strokeStyle = this.erasing ? GROUND() : this.color
    // The eraser is wider than the brush at the same setting, which is what
    // people expect from an eraser and cheaper than a second size control.
    this.ctx.lineWidth = this.erasing ? this.size * 3 : this.size
    this.ctx.lineTo(p.x, p.y)
    this.ctx.stroke()
    this.ctx.beginPath()
    this.ctx.moveTo(p.x, p.y)
  },

  stop() {
    this.drawing = false
  },

  clear() {
    const rect = this.el.getBoundingClientRect()
    this.ctx.fillStyle = GROUND()
    this.ctx.fillRect(0, 0, rect.width, rect.height)
  },
}
