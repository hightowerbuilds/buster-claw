// Hover and keyboard readout for the portfolio chart
// (PORTFOLIO_HISTORY_ROADMAP Phase 5).
//
// The plot is server-rendered SVG; this only reads it. Every point's coordinates
// AND its already-formatted sentence arrive on `data-readout`, so:
//
//   * no round-trip per mousemove — a crosshair that asks the server where it
//     should be is a crosshair that lags;
//   * the hover text, the keyboard readout, and the screen-reader announcement
//     are the same string, built once on the server, and cannot drift apart.
//
// The element carries phx-update="ignore", so the hook owns the DOM inside it
// between renders. `updated()` re-reads the data attribute because a range
// change replaces the whole series underneath us.
const VIEWBOX_WIDTH = 720

export const PortfolioChart = {
  mounted() {
    this.svg = this.el.querySelector("svg")
    this.crosshair = this.el.querySelector("[data-crosshair]")
    this.dot = this.el.querySelector("[data-crosshair-dot]")
    this.tooltip = this.el.querySelector("[data-tooltip]")
    this.live = this.el.querySelector("[data-live]")
    this.index = null

    this.readPoints()

    this.onMove = (e) => this.handleMove(e)
    this.onLeave = () => this.clear()
    this.onKey = (e) => this.handleKey(e)

    this.el.addEventListener("pointermove", this.onMove)
    this.el.addEventListener("pointerleave", this.onLeave)
    if (this.svg) {
      this.svg.addEventListener("keydown", this.onKey)
      this.svg.addEventListener("blur", this.onLeave)
    }
  },

  updated() {
    // A new range or a new account means new points; drop any stale selection
    // rather than pointing at an index that no longer exists.
    this.readPoints()
    this.clear()
  },

  destroyed() {
    this.el.removeEventListener("pointermove", this.onMove)
    this.el.removeEventListener("pointerleave", this.onLeave)
    if (this.svg) {
      this.svg.removeEventListener("keydown", this.onKey)
      this.svg.removeEventListener("blur", this.onLeave)
    }
  },

  readPoints() {
    try {
      this.points = JSON.parse(this.el.dataset.readout || "[]")
    } catch (_e) {
      this.points = []
    }
  },

  handleMove(e) {
    if (!this.points.length || !this.svg) return
    const rect = this.svg.getBoundingClientRect()
    if (!rect.width) return

    // preserveAspectRatio="none": the viewBox stretches to the rendered width,
    // so mapping is a plain ratio.
    const x = ((e.clientX - rect.left) / rect.width) * VIEWBOX_WIDTH
    this.select(this.nearestIndex(x))
  },

  handleKey(e) {
    if (!this.points.length) return
    const last = this.points.length - 1
    let next = this.index

    switch (e.key) {
      case "ArrowRight": next = this.index === null ? 0 : Math.min(this.index + 1, last); break
      case "ArrowLeft": next = this.index === null ? last : Math.max(this.index - 1, 0); break
      case "Home": next = 0; break
      case "End": next = last; break
      case "Escape": this.clear(); return
      default: return
    }

    e.preventDefault()
    this.select(next)
  },

  nearestIndex(x) {
    let best = 0
    let bestDistance = Infinity

    this.points.forEach((point, i) => {
      const distance = Math.abs(point.x - x)
      if (distance < bestDistance) {
        bestDistance = distance
        best = i
      }
    })

    return best
  },

  select(index) {
    const point = this.points[index]
    if (!point) return
    this.index = index

    if (this.crosshair) {
      this.crosshair.setAttribute("x1", point.x)
      this.crosshair.setAttribute("x2", point.x)
      this.crosshair.style.display = ""
    }

    if (this.dot) {
      this.dot.setAttribute("cx", point.x)
      this.dot.setAttribute("cy", point.y)
      this.dot.style.display = ""
    }

    if (this.tooltip) {
      this.tooltip.textContent = point.label
      this.tooltip.classList.remove("hidden")
      // Flip the tooltip to the left of the crosshair past the midpoint so it
      // never runs off the panel.
      const ratio = point.x / VIEWBOX_WIDTH
      this.tooltip.style.left = ratio > 0.5 ? "auto" : `${ratio * 100}%`
      this.tooltip.style.right = ratio > 0.5 ? `${(1 - ratio) * 100}%` : "auto"
      this.tooltip.style.top = "0px"
    }

    if (this.live) this.live.textContent = point.label
  },

  clear() {
    this.index = null
    if (this.crosshair) this.crosshair.style.display = "none"
    if (this.dot) this.dot.style.display = "none"
    if (this.tooltip) this.tooltip.classList.add("hidden")
  }
}
