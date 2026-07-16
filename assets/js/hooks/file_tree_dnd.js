// Drag-to-move inside the workspace file tree (FileTree LiveComponent, manage
// mode). Rows carry data-ft-path (+ data-ft-dir on folders); dropping a row onto
// a folder row pushes "drop_move" to the component, which calls FileManager.move.
//
// Event-delegated on the component root so it covers rows added as folders
// expand, with no per-row listeners. Uses a private dataTransfer type so an OS
// file drop (Part 3: upload) and an internal move never get confused — this hook
// only ever acts on drags carrying "application/x-buster-path".
const MIME = "application/x-buster-path"
const HILITE = ["outline", "outline-2", "outline-primary/70", "bg-primary/10"]

export const FileTreeDnd = {
  mounted() {
    this.hover = null

    this.onStart = (e) => {
      const row = e.target.closest("[data-ft-path]")
      if (!row) return
      e.dataTransfer.setData(MIME, row.dataset.ftPath)
      e.dataTransfer.effectAllowed = "move"
    }

    this.onOver = (e) => {
      const dir = this.dropTarget(e)
      if (!dir) return this.clearHover()
      e.preventDefault()
      e.dataTransfer.dropEffect = "move"
      this.setHover(dir)
    }

    this.onLeave = (e) => {
      // Only clear when actually leaving the hovered folder (not entering a child).
      if (this.hover && !this.hover.contains(e.relatedTarget)) this.clearHover()
    }

    this.onDrop = (e) => {
      const dir = this.dropTarget(e)
      this.clearHover()
      if (!dir) return
      e.preventDefault()
      const src = e.dataTransfer.getData(MIME)
      const dest = dir.dataset.ftPath
      if (src && dest && this.canMove(src, dest)) {
        this.pushEventTo(this.el, "drop_move", {src, dest})
      }
    }

    this.el.addEventListener("dragstart", this.onStart)
    this.el.addEventListener("dragover", this.onOver)
    this.el.addEventListener("dragleave", this.onLeave)
    this.el.addEventListener("drop", this.onDrop)
  },

  destroyed() {
    this.el.removeEventListener("dragstart", this.onStart)
    this.el.removeEventListener("dragover", this.onOver)
    this.el.removeEventListener("dragleave", this.onLeave)
    this.el.removeEventListener("drop", this.onDrop)
  },

  // The folder row under the pointer for an *internal* drag, or null. Ignores OS
  // file drops (no MIME type) so the LiveView upload target handles those.
  dropTarget(e) {
    if (!e.dataTransfer.types.includes(MIME)) return null
    return e.target.closest('[data-ft-dir="true"]')
  },

  // Reject a no-op (already in dest) and moving a folder into itself/a descendant.
  canMove(src, dest) {
    if (src === dest) return false
    if (dest === src.slice(0, src.lastIndexOf("/"))) return false // already the parent
    return !(dest === src || dest.startsWith(src + "/"))
  },

  setHover(dir) {
    if (this.hover === dir) return
    this.clearHover()
    this.hover = dir
    dir.classList.add(...HILITE)
  },

  clearHover() {
    if (this.hover) this.hover.classList.remove(...HILITE)
    this.hover = null
  },
}
