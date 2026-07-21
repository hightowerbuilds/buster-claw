export const CalendarDrag = {
  mounted() {
    let draggingId = null
    let lastTarget = null

    this.el.addEventListener("dragstart", (e) => {
      const chip = e.target.closest("[data-event-id]")
      if (!chip) return
      draggingId = chip.dataset.eventId
      e.dataTransfer.effectAllowed = "move"
      // some browsers need this for the drag to fire
      e.dataTransfer.setData("text/plain", draggingId)
      chip.classList.add("opacity-50")
    })

    this.el.addEventListener("dragend", (e) => {
      const chip = e.target.closest("[data-event-id]")
      if (chip) chip.classList.remove("opacity-50")
      if (lastTarget) {
        lastTarget.classList.remove("ring-2", "ring-base-content")
        lastTarget = null
      }
      draggingId = null
    })

    this.el.addEventListener("dragover", (e) => {
      const cell = e.target.closest("[data-drop-date]")
      if (!cell) return
      e.preventDefault()
      e.dataTransfer.dropEffect = "move"
      if (lastTarget !== cell) {
        if (lastTarget) lastTarget.classList.remove("ring-2", "ring-base-content")
        cell.classList.add("ring-2", "ring-base-content")
        lastTarget = cell
      }
    })

    this.el.addEventListener("dragleave", (e) => {
      const cell = e.target.closest("[data-drop-date]")
      if (cell && cell === lastTarget && !cell.contains(e.relatedTarget)) {
        cell.classList.remove("ring-2", "ring-base-content")
        lastTarget = null
      }
    })

    this.el.addEventListener("drop", (e) => {
      const cell = e.target.closest("[data-drop-date]")
      if (!cell || !draggingId) return
      e.preventDefault()
      const newDate = cell.dataset.dropDate
      cell.classList.remove("ring-2", "ring-base-content")
      lastTarget = null
      // The grid lives inside a LiveComponent (phx-target on its root), so route
      // the drop to that component rather than the host LiveView. pushEventTo with
      // this.el resolves the component via the nearest phx-target ancestor.
      this.pushEventTo(this.el, "move_event", {id: draggingId, date: newDate})
      draggingId = null
    })
  }
}

// Floating event popover for the home month grid. Hovering a day cell that has
// events shows a popover above the cell, populated from that cell's hidden
// [data-day-detail] block. The popover is appended to <body> so it escapes the
// widget's overflow clipping, and positioned fixed (above the cell, flipping
// below if there's no room). Nothing is shown at rest.
export const CalendarPopover = {
  mounted() {
    this.pop = document.createElement("div")
    this.pop.className = "ic-cal-popover"
    this.pop.hidden = true
    document.body.appendChild(this.pop)
    this.current = null

    this.onOver = (e) => {
      const cell = e.target.closest("[data-day][data-has-events]")
      if (!cell || !this.el.contains(cell)) { this.hide(); return }
      if (cell !== this.current) this.show(cell)
    }
    this.onLeave = () => this.hide()
    this.onScroll = () => this.hide()
    this.el.addEventListener("pointerover", this.onOver)
    this.el.addEventListener("pointerleave", this.onLeave)
    window.addEventListener("scroll", this.onScroll, true)
  },
  show(cell) {
    const detail = cell.querySelector("[data-day-detail]")
    if (!detail) { this.hide(); return }
    this.current = cell
    this.pop.innerHTML = detail.innerHTML
    // Measure off-screen, then place above the cell, centered + viewport-clamped.
    this.pop.style.visibility = "hidden"
    this.pop.hidden = false
    const r = cell.getBoundingClientRect()
    const pr = this.pop.getBoundingClientRect()
    let left = r.left + r.width / 2 - pr.width / 2
    left = Math.max(8, Math.min(left, window.innerWidth - pr.width - 8))
    let top = r.top - pr.height - 8
    if (top < 8) top = r.bottom + 8 // no room above → flip below
    this.pop.style.left = `${Math.round(left)}px`
    this.pop.style.top = `${Math.round(top)}px`
    this.pop.style.visibility = ""
  },
  hide() {
    this.current = null
    this.pop.hidden = true
  },
  destroyed() {
    this.el.removeEventListener("pointerover", this.onOver)
    this.el.removeEventListener("pointerleave", this.onLeave)
    window.removeEventListener("scroll", this.onScroll, true)
    this.pop.remove()
  },
}
