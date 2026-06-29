// Home Calendar/Contacts corner widget. Floats top-right; when the window
// narrows enough that the docked card would overlap the banner (#bc-heading),
// it collapses the card to a right-edge bumper. Clicking the bumper slides the
// card back out as an overlay; widening past the overlap re-docks it.
export const CornerWidget = {
  mounted() {
    this.card = this.el.querySelector("[data-corner-card]")
    this.bumper = this.el.querySelector("[data-corner-bumper]")
    this.banner = document.querySelector(this.el.dataset.banner || "#bc-heading")
    this.header = this.el.parentElement
    // Below this much free space to the right of the banner the widget can't
    // sit in the header usefully, so it collapses to the bumper.
    this.minWidth = 300
    this.gap = 16
    this.collapsed = null
    this.popped = false

    this.onBumper = () => this.setPopped(!this.popped)
    if (this.bumper) this.bumper.addEventListener("click", this.onBumper)
    // Clicking outside the popped overlay tucks it away again.
    this.onDocClick = (e) => {
      if (this.popped && !this.el.contains(e.target)) this.setPopped(false)
    }
    document.addEventListener("click", this.onDocClick)

    this.measure = () => this.update()
    this.ro = new ResizeObserver(this.measure)
    // Watch the header row and banner; their geometry decides the free gap.
    if (this.header) this.ro.observe(this.header)
    if (this.banner) this.ro.observe(this.banner)
    window.addEventListener("resize", this.measure)
    this.update()
  },
  destroyed() {
    if (this.ro) this.ro.disconnect()
    window.removeEventListener("resize", this.measure)
    document.removeEventListener("click", this.onDocClick)
    if (this.bumper) this.bumper.removeEventListener("click", this.onBumper)
  },
  // Collapse when the gap between the banner's right edge and the header's
  // right edge is too narrow to hold the widget. Measured off the header +
  // banner (not the widget's own width, which changes when it collapses), so
  // the decision is stable and doesn't oscillate at the threshold.
  update() {
    if (!this.header || !this.banner) return
    const headerRect = this.header.getBoundingClientRect()
    const bannerRect = this.banner.getBoundingClientRect()
    const available = headerRect.right - bannerRect.right - this.gap
    this.setCollapsed(available < this.minWidth)
  },
  setCollapsed(on) {
    if (this.collapsed === on) return
    this.collapsed = on
    this.el.classList.toggle("is-collapsed", on)
    if (!on) this.setPopped(false)
  },
  setPopped(on) {
    this.popped = on
    this.el.classList.toggle("is-popped", on)
  }
}
