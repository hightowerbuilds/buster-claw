// Notes keyboard paths: ⌘P to jump, ⌘N to start writing, arrows and Enter
// inside the switcher, Escape to back out.
//
// Mounted on the Notes panel root, which only exists while that tab is open —
// so none of these chords are bound anywhere else in the app.
//
// The chord table itself is `notesIntent/2` in lib/note_keys.js, where it can be
// tested; this hook is the wiring and the focus management around it. Escape
// only ever closes an overlay — it never discards a draft.

import {notesIntent} from "../lib/note_keys.js"

export const NotesKeys = {
  mounted() {
    this.onKeyDown = this.onKeyDown.bind(this)
    window.addEventListener("keydown", this.onKeyDown)
  },

  updated() {
    // The switcher just opened: put the caret in it. Tracked so a later patch
    // (a keystroke changing the result list) does not steal focus back to the
    // start of the field.
    if (this.switcherOpen()) {
      if (!this.focused) {
        this.focused = true
        this.el.querySelector("#note-switcher-input")?.focus()
      }
    } else {
      this.focused = false
    }

    if (this.pendingFocus) {
      const target = this.el.querySelector(this.pendingFocus)
      this.pendingFocus = null
      target?.focus()
    }
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeyDown)
  },

  switcherOpen() {
    return this.el.dataset.switcherOpen === "true"
  },

  onKeyDown(event) {
    const intent = notesIntent(event, {switcherOpen: this.switcherOpen()})
    if (!intent) return

    event.preventDefault()

    switch (intent) {
      case "switcher":
        return this.pushEventTo(this.el, "open_switcher", {})
      case "new":
        // The server clears the selection first, which is what un-hides the rail
        // on a narrow window; focus lands in `updated()` once that has rendered.
        this.pendingFocus = "#new-note-title"
        return this.pushEventTo(this.el, "new_note", {})
      case "close":
        return this.pushEventTo(this.el, "close_switcher", {})
      case "select":
        return this.pushEventTo(this.el, "switcher_select", {})
      default:
        return this.pushEventTo(this.el, "switcher_move", {dir: intent})
    }
  },
}
