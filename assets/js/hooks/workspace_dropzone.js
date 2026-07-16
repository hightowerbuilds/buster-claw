// Visual affordance for dragging OS files (Finder → the app) into the workspace
// explorer. The actual upload is handled by LiveView's phx-drop-target on the
// same element; this hook only toggles a "drop files here" overlay while real
// files are dragged over, and ignores the tree's own internal move drags (which
// carry our private MIME type, not "Files").
//
// Requires the Tauri main window's dragDropEnabled:false so OS drops surface as
// DOM drag events instead of being swallowed natively.
export const WorkspaceDropzone = {
  mounted() {
    this.depth = 0

    const hasFiles = (e) => Array.from(e.dataTransfer?.types || []).includes("Files")
    const active = (on) => this.el.classList.toggle("bc-dropzone-active", on)

    this.onEnter = (e) => {
      if (!hasFiles(e)) return
      this.depth++
      active(true)
    }
    this.onOver = (e) => {
      if (hasFiles(e)) e.preventDefault() // required for the drop to fire
    }
    this.onLeave = (e) => {
      if (!hasFiles(e)) return
      this.depth = Math.max(0, this.depth - 1)
      if (this.depth === 0) active(false)
    }
    this.onDrop = () => {
      this.depth = 0
      active(false)
    }

    this.el.addEventListener("dragenter", this.onEnter)
    this.el.addEventListener("dragover", this.onOver)
    this.el.addEventListener("dragleave", this.onLeave)
    this.el.addEventListener("drop", this.onDrop)
  },

  destroyed() {
    this.el.removeEventListener("dragenter", this.onEnter)
    this.el.removeEventListener("dragover", this.onOver)
    this.el.removeEventListener("dragleave", this.onLeave)
    this.el.removeEventListener("drop", this.onDrop)
  },
}
