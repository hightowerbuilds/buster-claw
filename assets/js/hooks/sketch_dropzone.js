// Dropping and pasting images into the Sketch Pad.
//
// `ChatDropzone`'s shape applied to a third surface, and for the same reason it
// has that shape: **macOS WKWebView does NOT hand file contents to the DOM on an
// OS drag.** In the packaged app we get a *path* from Tauri's native drag-drop
// event and the server reads the file; in a dev browser we get real bytes
// through the HTML5 upload. **Only one is ever live per environment**, so
// nothing is ever added twice.
//
// A surface wired only to `phx-drop-target` therefore works perfectly in
// `mix phx.server` and does nothing at all in the DMG — which is the product.
// See SKETCH_ROADMAP D12.
//
// Paste is bound in BOTH environments and that is not a contradiction: the
// WKWebView limitation is about an OS *drag*, where the app is handed a promised
// file rather than its contents. A pasteboard carries no promise — a copied
// screenshot is real bytes in `clipboardData` in the packaged app as much as in
// a browser. What it will NOT give us is a file copied in Finder, which arrives
// as a reference with no `files` behind it; that is what the drag path is for.
//
// The accept/refuse judgement is `../lib/attachments.js`, shared with the chat
// and under `bun test`, so a refusal reads the same sentence whichever surface
// and whichever gesture produced it. This file is DOM plumbing and two
// transports.
//
// ## Events pushed
//
//   "drop_point"    %{"x" => .., "y" => ..}                   where it landed
//   "drop_paths"    %{"paths" => [...]}                       Tauri only
//   "drop_refused"  %{"reason" => .., "filename" => ..}       a client refusal

import {inspectFiles, inspectPaths} from "../lib/attachments.js"

// Images only. The chat takes any file; a sketch can only draw these four, and
// refusing a `.zip` at the drop beats uploading it and failing afterwards.
const IMAGE_TYPES = /^image\/(png|jpeg|gif|webp)$/i
const IMAGE_NAMES = /\.(png|jpe?g|gif|webp)$/i

export default {
  mounted() {
    this.unlisten = []
    this.active = (on) => this.el.classList.toggle("bc-dropzone-active", on)

    if (window.__TAURI__?.event?.listen) {
      this.setupTauri()
    } else {
      this.setupBrowser()
    }

    this.bindPaste()
  },

  destroyed() {
    this.unlisten.forEach((off) => off && off())
    this.el.removeEventListener("paste", this.onPaste)
  },

  limits() {
    return {
      maxBytes: parseInt(this.el.dataset.maxBytes, 10) || undefined,
      maxFiles: parseInt(this.el.dataset.maxFiles, 10) || undefined,
    }
  },

  // Where a gesture landed, in the drawing surface's own coordinates. Sent
  // BEFORE the bytes, because uploading is asynchronous and by the time it
  // finishes the pointer is somewhere else entirely.
  reportPoint(clientX, clientY) {
    const svg = this.el.querySelector("[data-sketch-svg]")
    if (!svg) return

    const rect = svg.getBoundingClientRect()
    const x = clientX == null ? rect.width / 2 : clientX - rect.left
    const y = clientY == null ? rect.height / 2 : clientY - rect.top

    this.pushEventTo(this.el, "drop_point", {x: Math.round(x), y: Math.round(y)})
  },

  // --- browser transport ----------------------------------------------------

  setupBrowser() {
    const over = (e) => {
      e.preventDefault()
      this.active(true)
    }

    const leave = (e) => {
      // `dragleave` fires when the pointer crosses onto a CHILD element too, so
      // the overlay would flicker over its own contents without this.
      if (e.relatedTarget && this.el.contains(e.relatedTarget)) return
      this.active(false)
    }

    const drop = (e) => {
      e.preventDefault()
      // LiveView binds its own window-level drop handler for `phx-drop-target`
      // and feeds it the ENTIRE FileList. A FileList cannot be filtered in
      // place, so that handler can only take all of a drop or none of it —
      // "upload it, then fail" is what refusing at the drop rules out.
      e.stopPropagation()
      this.active(false)

      this.reportPoint(e.clientX, e.clientY)
      this.takeFiles(Array.from(e.dataTransfer?.files || []))
    }

    this.el.addEventListener("dragover", over)
    this.el.addEventListener("dragenter", over)
    this.el.addEventListener("dragleave", leave)
    this.el.addEventListener("drop", drop)

    this.unlisten.push(() => {
      this.el.removeEventListener("dragover", over)
      this.el.removeEventListener("dragenter", over)
      this.el.removeEventListener("dragleave", leave)
      this.el.removeEventListener("drop", drop)
    })
  },

  // --- tauri transport ------------------------------------------------------

  async setupTauri() {
    const listen = window.__TAURI__.event.listen

    const hovering = await listen("tauri://drag-enter", () => this.active(true))
    const left = await listen("tauri://drag-leave", () => this.active(false))
    const dropped = await listen("tauri://drag-drop", (event) => {
      this.active(false)

      const payload = event?.payload || {}
      const position = payload.position || {}
      // Tauri reports physical pixels; the DOM works in CSS pixels.
      const ratio = window.devicePixelRatio || 1
      const hasPoint = typeof position.x === "number"

      this.reportPoint(
        hasPoint ? position.x / ratio : null,
        hasPoint ? position.y / ratio : null,
      )

      this.takePaths(payload.paths || [])
    })

    this.unlisten.push(hovering, left, dropped)
  },

  takePaths(paths) {
    if (paths.length === 0) return

    const named = paths.filter((p) => IMAGE_NAMES.test(p))
    const {accepted, rejected} = inspectPaths(named, this.limits())

    // A path drop has no size to check, so the server re-checks everything. The
    // name filter here is only to keep an obvious non-image from making a round
    // trip.
    paths
      .filter((p) => !IMAGE_NAMES.test(p))
      .forEach((p) => this.refuse("unsupported_type", p))

    rejected.forEach((r) => this.refuse(r.reason, r.filename))

    if (accepted.length > 0) {
      this.pushEventTo(this.el, "drop_paths", {paths: accepted.map((a) => a.path || a.filename)})
    }
  },

  // --- shared ---------------------------------------------------------------

  // One route for dropped and pasted bytes, so a refusal reads identically
  // whichever gesture produced it.
  takeFiles(files) {
    if (files.length === 0) return // an empty drop is a no-op, not an error

    const images = files.filter((f) => IMAGE_TYPES.test(f.type) || IMAGE_NAMES.test(f.name))
    files
      .filter((f) => !images.includes(f))
      .forEach((f) => this.refuse("unsupported_type", f.name))

    if (images.length === 0) return

    const {accepted, rejected} = inspectFiles(
      images.map((f) => ({name: f.name, type: f.type, size: f.size})),
      this.limits(),
    )

    rejected.forEach((r) => this.refuse(r.reason, r.filename))
    if (accepted.length === 0) return

    const keep = new Set(accepted.map((a) => a.filename))
    const survivors = images.filter((f) => keep.has(f.name))

    // `track-uploads` is the supported way to hand LiveView a list of `File`
    // objects the page chose. The upload is still LiveView's — only the choice
    // of what gets uploaded is ours, and it is made before a byte moves.
    const input = this.el.querySelector("input[data-phx-upload-ref]")
    if (input && survivors.length > 0) {
      this.el.dispatchEvent(
        new CustomEvent("track-uploads", {bubbles: true, detail: {files: survivors}}),
      )
    }
  },

  bindPaste() {
    this.onPaste = (e) => {
      const files = Array.from(e.clipboardData?.files || [])
      if (files.length === 0) return

      // A paste has no coordinates, so it lands in the middle of the surface —
      // which is where someone looking at the pad expects it.
      this.reportPoint(null, null)

      const types = Array.from(e.clipboardData?.types || [])
      if (!types.includes("text/plain")) e.preventDefault()

      this.takeFiles(files)
    }

    this.el.addEventListener("paste", this.onPaste)
  },

  refuse(reason, filename) {
    this.pushEventTo(this.el, "drop_refused", {reason, filename})
  },
}
