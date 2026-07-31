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
