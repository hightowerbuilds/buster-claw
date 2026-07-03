// Tracks the pointer over a `.ic-scanlines` heading and writes its position
// into --crt-x/--crt-y so the CSS reveals a stronger chromatic-aberration
// overlay in a circle under the cursor. Throttled to one write per frame; no
// server round-trips. Toggles data-crt-active to fade the overlay in/out.
export const CrtAberration = {
  mounted() {
    this.frame = null
    this.onEnter = () => this.el.setAttribute("data-crt-active", "1")
    this.onLeave = () => {
      this.el.setAttribute("data-crt-active", "0")
      if (this.frame) cancelAnimationFrame(this.frame)
      this.frame = null
    }
    this.onMove = (e) => {
      const rect = this.el.getBoundingClientRect()
      this.x = e.clientX - rect.left
      this.y = e.clientY - rect.top
      if (this.frame) return
      this.frame = requestAnimationFrame(() => {
        this.frame = null
        this.el.style.setProperty("--crt-x", `${this.x}px`)
        this.el.style.setProperty("--crt-y", `${this.y}px`)
      })
    }
    this.el.addEventListener("pointerenter", this.onEnter)
    this.el.addEventListener("pointerleave", this.onLeave)
    this.el.addEventListener("pointermove", this.onMove)
  },
  destroyed() {
    this.el.removeEventListener("pointerenter", this.onEnter)
    this.el.removeEventListener("pointerleave", this.onLeave)
    this.el.removeEventListener("pointermove", this.onMove)
    if (this.frame) cancelAnimationFrame(this.frame)
  },
}
