// Dropping OS files (Finder → the app) into the workspace explorer.
//
// macOS WKWebView does NOT hand file *contents* to the DOM on an OS drop, so the
// HTML5 upload path only works in a plain browser (dev). In the Tauri app we use
// the native drag-drop event, which delivers real file *paths*; the server then
// copies them into the folder in view by path (efficient, and it doesn't care
// that the workspace root may be a symlink — the OS follows it). Both paths key
// off the same overlay and push "import_paths" (Tauri) / phx-drop-target upload
// (browser); only one is ever live per environment, so no double import.
export const WorkspaceDropzone = {
  mounted() {
    this.unlisten = []
    this.active = (on) => this.el.classList.toggle("bc-dropzone-active", on)

    if (window.__TAURI__?.event?.listen) {
      this.setupTauri()
    } else {
      this.setupHtml5()
    }
  },

  async setupTauri() {
    const {listen} = window.__TAURI__.event
    const off = async (name, cb) => this.unlisten.push(await listen(name, cb))

    // Native drag events are window-global; this hook only exists while the
    // workspace tab is mounted, so reacting to any drop here means "into the
    // workspace." Files land in the folder currently in view (server side).
    await off("tauri://drag-enter", () => this.active(true))
    await off("tauri://drag-over", () => this.active(true))
    await off("tauri://drag-leave", () => this.active(false))
    await off("tauri://drag-drop", (e) => {
      this.active(false)
      const paths = e?.payload?.paths
      if (Array.isArray(paths) && paths.length) this.pushEvent("import_paths", {paths})
    })
  },

  setupHtml5() {
    this.depth = 0
    const hasFiles = (e) => Array.from(e.dataTransfer?.types || []).includes("Files")

    this.onEnter = (e) => {
      if (!hasFiles(e)) return
      this.depth++
      this.active(true)
    }
    this.onOver = (e) => {
      if (hasFiles(e)) e.preventDefault() // required for the drop to fire
    }
    this.onLeave = (e) => {
      if (!hasFiles(e)) return
      this.depth = Math.max(0, this.depth - 1)
      if (this.depth === 0) this.active(false)
    }
    this.onDrop = () => {
      this.depth = 0
      this.active(false)
    }

    this.el.addEventListener("dragenter", this.onEnter)
    this.el.addEventListener("dragover", this.onOver)
    this.el.addEventListener("dragleave", this.onLeave)
    this.el.addEventListener("drop", this.onDrop)
  },

  destroyed() {
    this.unlisten.forEach((fn) => {
      try {
        fn()
      } catch (_e) {
        /* already gone */
      }
    })
    if (this.onEnter) {
      this.el.removeEventListener("dragenter", this.onEnter)
      this.el.removeEventListener("dragover", this.onOver)
      this.el.removeEventListener("dragleave", this.onLeave)
      this.el.removeEventListener("drop", this.onDrop)
    }
  },
}
