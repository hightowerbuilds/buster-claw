// The Notes editor's browser ergonomics — and nothing else.
//
// Save authority stays in `NotesComponent`: this hook never decides what the
// file contains, only when to ask the server about it. Four jobs:
//
//   1. **Dirty**. `phx-debounce` means the server hears nothing for 700ms after
//      a keystroke, so without this the status chip would read "Saved" over a
//      draft that is not saved. One `note_dirty` per clean->dirty transition,
//      not one per keystroke; the server owns the label from there.
//   2. **⌘S / Ctrl+S**. Submits the form, which is already wired to the same
//      save the debounce fires. The browser's own "save page" is not useful in
//      an editor and stealing it here is expected.
//   3. **Revision check** on window focus and on a slow tick. A note is an
//      ordinary file: another editor, or the agent, can change it while this tab
//      sits idle. Checking on the way back in is what turns a silent overwrite
//      into the conflict banner.
//   4. **Copy my draft**, so "Reload disk version" is never the only way out of
//      a conflict.
//
// The hook sits on the editor PANE, not the form, because the conflict banner
// and its copy button live outside the form and it needs to hear both.

import {isSaveChord, shouldAnnounceDirty} from "../lib/note_keys.js"

// Slow on purpose. The focus check covers the case that actually matters (you
// were away and something changed); this only catches a second window on the
// same screen, and every tick is a stat plus a read.
const POLL_MS = 20000

export const NoteEditor = {
  mounted() {
    this.dirty = false

    this.onInput = this.onInput.bind(this)
    this.onKeyDown = this.onKeyDown.bind(this)
    this.onClick = this.onClick.bind(this)
    this.onFocus = this.onFocus.bind(this)

    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("keydown", this.onKeyDown)
    this.el.addEventListener("click", this.onClick)
    window.addEventListener("focus", this.onFocus)
    this.timer = setInterval(this.onFocus, POLL_MS)
  },

  updated() {
    // The server re-rendered with its own idea of the save state. Anything but
    // "unsaved" means the draft in the textarea is no longer ahead of it, so the
    // next keystroke gets to announce itself again.
    if (this.state() !== "unsaved") this.dirty = false
  },

  destroyed() {
    clearInterval(this.timer)
    window.removeEventListener("focus", this.onFocus)
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("keydown", this.onKeyDown)
    this.el.removeEventListener("click", this.onClick)
  },

  state() {
    return this.el.dataset.saveState
  },

  textarea() {
    return this.el.querySelector("textarea")
  },

  onInput(event) {
    if (event.target !== this.textarea()) return
    if (!shouldAnnounceDirty({dirty: this.dirty, state: this.state()})) return

    this.dirty = true
    this.pushEventTo(this.el, "note_dirty", {})
  },

  onKeyDown(event) {
    if (!isSaveChord(event)) return

    const form = this.el.querySelector("form[data-note-editor]")
    if (!form) return

    event.preventDefault()
    form.requestSubmit()
  },

  onClick(event) {
    const button = event.target.closest("[data-note-copy-draft]")
    if (button) {
      event.preventDefault()
      this.copyDraft(button)
      return
    }

    const link = event.target.closest("[data-note-links] a[href^='#note']")
    if (link) this.openLink(event, link)
  },

  // Wiki links render as `#note/<path>` for a note that exists and
  // `#note-new/<title>` for one that does not. Fragments rather than paths so an
  // unhandled click is inert instead of a 404, and the href is the only thing
  // carrying the target — the sanitizer strips data attributes off note HTML.
  openLink(event, link) {
    const href = link.getAttribute("href")
    const [, kind, value] = /^#(note|note-new)\/(.*)$/.exec(href) || []
    if (!value) return

    event.preventDefault()
    const decoded = decodeURIComponent(value.replace(/\+/g, " "))

    if (kind === "note") {
      this.pushEventTo(this.el, "open_link", {path: decoded})
    } else {
      this.pushEventTo(this.el, "create_link", {title: decoded})
    }
  },

  onFocus() {
    if (this.el.dataset.notePath) this.pushEventTo(this.el, "check_revision", {})
  },

  // execCommand is the fallback rather than the primary: the async clipboard API
  // is the one that works when the page is not the focused document, which is
  // exactly the situation a conflict tends to arrive in.
  copyDraft(button) {
    const textarea = this.textarea()
    if (!textarea) return

    const done = () => {
      const original = button.dataset.noteCopyDraft || button.textContent
      button.dataset.noteCopyDraft = original
      button.textContent = "Copied"
      setTimeout(() => { button.textContent = original }, 1500)
    }

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(textarea.value).then(done, () => this.copyBySelection(textarea, done))
    } else {
      this.copyBySelection(textarea, done)
    }
  },

  copyBySelection(textarea, done) {
    const start = textarea.selectionStart
    const end = textarea.selectionEnd

    textarea.select()
    try {
      if (document.execCommand("copy")) done()
    } catch (_error) {
      // Nothing left to try; the draft is still on screen and still on disk-safe
      // hold, which is the guarantee that actually matters.
    }
    textarea.setSelectionRange(start, end)
  },
}
