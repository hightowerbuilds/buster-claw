// Right-click → Delete for the Studio sidebar.
//
// The menu is a component-rendered element under `phx-update="ignore"`; this
// hook owns its position, visibility, and confirm state. Deleting a file is
// irreversible, so the first click ARMS the button ("Really delete?") and only
// the second click pushes — an inline two-step instead of a native confirm(),
// which would block the webview's event loop and freeze LiveView.
//
// `contextmenu` binds on the document, scoped by existence: this element only
// exists while the Studio tab is open (same argument as StudioKeys), and only
// a press on a sidebar item marked deletable hijacks the native menu — a
// built-in chime or a voicemail recording gets the browser's own menu, because
// there is nothing of yours to delete there.

export const StudioContextMenu = {
  mounted() {
    this.button = this.el.querySelector("[data-ctx-delete]")
    this.targetId = null
    this.armed = false

    this.onContext = (e) => {
      const item = e.target.closest("[data-studio-source]")
      if (!item || !item.dataset.deletable) {
        this.hide()
        return
      }
      e.preventDefault()
      this.show(item, e.clientX, e.clientY)
    }
    // Capture phase, so a click that selects another source still dismisses.
    this.onAway = (e) => {
      if (!this.el.contains(e.target)) this.hide()
    }
    this.onKey = (e) => {
      if (e.key === "Escape") this.hide()
    }
    this.onDelete = (e) => {
      e.preventDefault()
      if (!this.armed) {
        this.arm()
        return
      }
      this.pushEventTo(this.el, "delete_source", {id: this.targetId})
      this.hide()
    }

    document.addEventListener("contextmenu", this.onContext)
    document.addEventListener("pointerdown", this.onAway, true)
    window.addEventListener("keydown", this.onKey)
    this.button.addEventListener("click", this.onDelete)
  },

  destroyed() {
    document.removeEventListener("contextmenu", this.onContext)
    document.removeEventListener("pointerdown", this.onAway, true)
    window.removeEventListener("keydown", this.onKey)
  },

  show(item, x, y) {
    this.targetId = item.dataset.studioSource
    this.disarm(item.dataset.sourceLabel || item.dataset.studioSource)
    this.el.hidden = false
    // Measure after unhiding (a hidden element has no box), then clamp so the
    // menu never opens half off-screen near the window edge.
    const r = this.el.getBoundingClientRect()
    this.el.style.left = `${Math.min(x, window.innerWidth - r.width - 8)}px`
    this.el.style.top = `${Math.min(y, window.innerHeight - r.height - 8)}px`
  },

  hide() {
    this.el.hidden = true
    this.targetId = null
    this.armed = false
  },

  arm() {
    this.armed = true
    this.button.textContent = "Really delete?"
    this.button.classList.add("text-error")
  },

  disarm(label) {
    this.armed = false
    this.button.textContent = `Delete ${label}`
    this.button.classList.remove("text-error")
  },
}
