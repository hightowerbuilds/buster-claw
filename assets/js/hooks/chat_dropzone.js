import {MAX_BYTES, MAX_FILES, inspectFiles, inspectPaths} from "../lib/attachments.js"

// Dropping and pasting files into the homepage chat.
//
// This is `WorkspaceDropzone`'s shape applied to the chat, for the same reason
// it has that shape: **macOS WKWebView does NOT hand file *contents* to the DOM
// on an OS drop.** In the packaged app we get a *path* from the Tauri native
// drag-drop event and the server reads the file; in a dev browser we get real
// bytes through the HTML5 upload. Both light the same overlay; **only one is
// ever live per environment**, so nothing is ever attached twice.
//
// What is new here, and is the whole point of the hook, is that a drop can be
// *refused* — and it has to be refused at the drop, while a message is still
// cheap and obviously about the file the user just let go of. Every judgement
// lives in `../lib/attachments.js` under `bun test`; this file is DOM plumbing
// and two transports.
//
// ## Why the drop is taken here rather than left to `phx-drop-target`
//
// The markup carries `phx-drop-target` and LiveView binds its own window-level
// `drop` handler for it — one that feeds the **entire** `dataTransfer.files`
// list to the upload input. A `FileList` cannot be filtered in place, so that
// handler can only accept all of a drop or none of it, and "upload it, then
// fail" is exactly what decision 6 rules out.
//
// So the element handler here takes the drop first and calls `stopPropagation`
// so LiveView's never runs, then hands the **survivors** back through
// LiveView's own `track-uploads` event — the supported way to give it a list of
// `File` objects the page chose. The upload itself is still LiveView's; only
// the choice of what gets uploaded is ours, and it is made before a byte moves.
//
// ## The DOM contract (owned by `ChatPanel`, on the server side)
//
//   phx-hook="ChatDropzone"    the wrapper around the log and the composer
//   .bc-drop-overlay child     the overlay; app.css reveals it on the active class
//   live_file_input inside     found by `[data-phx-upload-ref]`, or named
//                              explicitly with `data-attach-input="ID"`
//   data-max-bytes             optional caps, so both ends quote one number.
//   data-max-files             Absent, the defaults in `../lib/attachments.js`
//   data-attach-count          apply — they are the server's numbers already.
//
// The refusal *banner* is deliberately not written to from here. The server
// renders `[data-attach-error]` complete with its dismiss button, so a
// `textContent` write from a hook would delete the way out of it. The push is
// the whole channel.
//
// ## Events pushed
//
//   "attach_paths"   %{"paths" => [...]}                    Tauri only
//   "attach_error"   %{"reason" => ..., "filename" => ...}   a client refusal
//
// The reasons use the server's vocabulary — `too_large`, `too_many`, `empty`,
// `unsupported_type` — so one sentence comes back however the file was refused.
export const ChatDropzone = {
  mounted() {
    this.unlisten = []
    this.active = (on) => this.el.classList.toggle("bc-dropzone-active", on)

    if (window.__TAURI__?.event?.listen) {
      this.setupTauri()
    } else {
      this.setupHtml5()
    }

    this.bindPaste()
  },

  // --- transport: the packaged app ------------------------------------------

  async setupTauri() {
    // Bound first and synchronously, before any `await`: it is the cheap half of
    // the bug being fixed, and it must not be waiting on a promise if the user
    // drops something a frame after mount.
    //
    // Belt and braces, because if this webview ever does deliver a DOM drop as
    // well (drag-drop interception is a per-platform behaviour of the runtime,
    // not a promise), the default action is to navigate the window to the
    // dropped file and unload the whole app. These listeners attach nothing —
    // the native path below does the work — they only refuse to let it leave.
    this.guardDefaults()

    const {listen} = window.__TAURI__.event
    const off = async (name, cb) => this.unlisten.push(await listen(name, cb))

    // The native drag events are window-global — `tauri://drag-leave` does not
    // even carry a payload, and the others report a *physical-pixel*,
    // window-relative `position` rather than anything the DOM could hit-test
    // cheaply. `WorkspaceDropzone` reasons about this the same way and reaches
    // the same conclusion: the hook only exists while its surface is mounted,
    // so a native drop while it is alive means "into the chat". The workspace
    // explorer lives on another route, so the two are never listening at once.
    await off("tauri://drag-enter", () => this.active(true))
    await off("tauri://drag-over", () => this.active(true))
    await off("tauri://drag-leave", () => this.active(false))
    await off("tauri://drag-drop", (e) => {
      this.active(false)
      this.takePaths(e?.payload?.paths)
    })
  },

  takePaths(paths) {
    if (!Array.isArray(paths) || paths.length === 0) return

    // A path carries no size, so nothing here can enforce the byte cap: the
    // server size-checks before it reads, which is what `Attachment`'s
    // `:native_path` source is for. Type, name and count are checked, and the
    // rest is honestly the server's.
    const {accepted, rejected} = inspectPaths(paths, this.limits())
    rejected.forEach((r) => this.refuse(r))

    if (accepted.length) this.pushEvent("attach_paths", {paths: accepted.map((a) => a.path)})
  },

  // --- transport: a dev browser ---------------------------------------------

  setupHtml5() {
    // `dragleave` fires every time the pointer crosses into a CHILD element, so
    // a naive "leave means hide" flickers the overlay off and on as the pointer
    // moves over the message bubbles and the composer. Counting enter/leave
    // pairs is the fix: the overlay hides only when the count returns to zero,
    // i.e. when the pointer has actually left the panel. `drop` resets the
    // counter outright, because a drop consumes the pending leaves.
    this.depth = 0
    const hasFiles = (e) => Array.from(e.dataTransfer?.types || []).includes("Files")

    this.onEnter = (e) => {
      if (!hasFiles(e)) return
      this.depth++
      this.active(true)
    }
    this.onOver = (e) => {
      // Prevented for EVERY drag, not only files. Two reasons: without it the
      // `drop` event never fires at all, and whatever was dragged (a link, a
      // file, a selection) is then handled by the webview's own default, which
      // is to navigate away from the application. The cursor still tells the
      // truth, because `dropEffect` only says "copy" when there is something
      // here we can actually take.
      e.preventDefault()
      if (e.dataTransfer) e.dataTransfer.dropEffect = hasFiles(e) ? "copy" : "none"
    }
    this.onLeave = (e) => {
      if (!hasFiles(e)) return
      this.depth = Math.max(0, this.depth - 1)
      if (this.depth === 0) this.active(false)
    }
    this.onDrop = (e) => {
      e.preventDefault()
      e.stopPropagation() // see the note above: LiveView's own handler must not also run
      this.depth = 0
      this.active(false)
      this.takeFiles(Array.from(e.dataTransfer?.files || []))
    }

    this.el.addEventListener("dragenter", this.onEnter)
    this.el.addEventListener("dragover", this.onOver)
    this.el.addEventListener("dragleave", this.onLeave)
    this.el.addEventListener("drop", this.onDrop)
  },

  // Drops we cannot do anything with still must not navigate the app away. A
  // refusal is a bad outcome; unloading the application because the user missed
  // the panel is a much worse one.
  guardDefaults() {
    this.onOver = (e) => e.preventDefault()
    this.onDrop = (e) => e.preventDefault()
    this.el.addEventListener("dragover", this.onOver)
    this.el.addEventListener("drop", this.onDrop)
  },

  // --- paste ----------------------------------------------------------------

  // Paste lives HERE and not in `Composer` on purpose. `Composer` is the
  // keyboard contract shared by both chat surfaces, and only this one takes
  // attachments; more importantly a pasted image has to pass the *same*
  // refusals as a dropped one, and splitting that across two hooks is how the
  // two drift. `paste` bubbles, so listening on the panel catches the composer's
  // textarea inside it without either hook knowing about the other.
  //
  // Paste is bound in BOTH environments, which looks like it contradicts the
  // one-path-per-environment rule above and does not: the WKWebView limitation
  // is about an OS *drag*, where the app is handed a promised file rather than
  // its contents. The pasteboard has no such promise — a copied screenshot is
  // real bytes in `clipboardData`, in the packaged app as much as in a browser,
  // and it uploads exactly like a dev-browser drop. What the packaged app will
  // NOT give us is a file copied in Finder and pasted here: that arrives as a
  // reference with no `files` behind it, and this handler correctly does
  // nothing with it — which is what the native drag path is for.
  bindPaste() {
    this.onPaste = (e) => {
      const files = Array.from(e.clipboardData?.files || [])
      if (files.length === 0) return

      // A clipboard can hold a file *and* text (copying an image out of a web
      // page is the usual case). The text still belongs in the textarea, so the
      // default is only cancelled when the clipboard is files-only.
      const types = Array.from(e.clipboardData?.types || [])
      if (!types.includes("text/plain")) e.preventDefault()

      this.takeFiles(files)
    }

    this.el.addEventListener("paste", this.onPaste)
  },

  // --- shared ---------------------------------------------------------------

  // One route for dropped and pasted bytes, so a refusal reads identically
  // whichever gesture produced it.
  takeFiles(files) {
    if (files.length === 0) return // an empty drop is a no-op, not an error

    const {accepted, rejected} = inspectFiles(
      files.map((f) => ({name: f.name, type: f.type, size: f.size})),
      this.limits()
    )
    rejected.forEach((r) => this.refuse(r))
    if (accepted.length === 0) return

    const input = this.uploadInput()
    if (!input) {
      // The markup has no upload input yet. Say so rather than swallowing the
      // gesture — the drop was already prevented above, so at least the app is
      // still on screen.
      return this.refuse({reason: "unavailable", filename: accepted[0].filename})
    }

    // LiveView's own `track-uploads` event is the supported way to hand it a
    // list of `File` objects *we* chose, which is exactly what filtering a drop
    // requires. It must bubble: the listener is on the window.
    input.dispatchEvent(
      new CustomEvent("track-uploads", {
        bubbles: true,
        detail: {files: accepted.map((a) => files[a.index])},
      })
    )
  },

  uploadInput() {
    const id = this.el.dataset.attachInput
    return (
      (id && document.getElementById(id)) ||
      this.el.querySelector("input[type=file][data-phx-upload-ref]")
    )
  },

  limits() {
    const {maxBytes, maxFiles, attachCount} = this.el.dataset
    return {
      maxBytes: Number(maxBytes) || MAX_BYTES,
      maxFiles: Number(maxFiles) || MAX_FILES,
      existing: Number(attachCount) || 0,
    }
  },

  // Refuse VISIBLY — the server turns this into the banner above the composer,
  // in the same words it uses for its own refusals.
  //
  // `describeRefusal` is not sent: the sentence is the server's to write, and
  // two copies of the copy would drift. It stays exported and tested because it
  // is what a surface *without* a server-rendered banner would need, and
  // because the reason codes have to mean something on their own.
  refuse(r) {
    this.pushEvent("attach_error", {reason: r.reason, filename: r.filename})
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
      this.el.removeEventListener("dragleave", this.onLeave)
    }
    if (this.onOver) {
      this.el.removeEventListener("dragover", this.onOver)
      this.el.removeEventListener("drop", this.onDrop)
    }
    this.el.removeEventListener("paste", this.onPaste)
  },
}
