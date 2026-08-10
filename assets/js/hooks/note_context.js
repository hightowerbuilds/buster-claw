// The two gestures that replaced the Notes header's pencil and trash buttons
// (daily-growth/archive/08-09-26-notes-editor.md W1 and W2). Both are here because they are the same
// finding twice: a word processor renames by its title and deletes from its
// file list, and neither command deserves a permanent control two centimetres
// from the writing surface.
//
// Neither hook holds state the server needs. `toggle_rename` and `delete_note`
// already existed for the buttons; all that changed is what summons them.

import {menuPosition} from "../lib/note_menu.js"

// Right-click a row in the rail to delete that note. Modelled on
// StudioContextMenu, deliberately — a second right-click convention in one app
// is a worse outcome than any improvement a different one could offer.
//
// `contextmenu` binds on the document, scoped by existence: the rail is only in
// the DOM while the Notes tab is open, and only a press on a row (which the
// server marks with `data-note-row`) hijacks the native menu.
//
// ## The delete item is the old header button, moved
//
// It keeps `phx-click="delete_note"`, `phx-target` and `data-claw-confirm`, so
// the whole destructive path — confirm dialog, event, server handler — is the
// one that already shipped. This hook only fills in the half that depends on
// which row was pressed. That is why nothing here calls `pushEventTo`: LiveView
// and the confirm interceptor both read the attributes at click time.
export const NoteContextMenu = {
  mounted() {
    // A missing node becomes an inert stand-in rather than null: a renamed data
    // attribute must not throw in `mounted()` and take the contextmenu listener
    // down with it, which is how StudioContextMenu once silently stopped
    // existing rather than losing one item.
    this.item = this.el.querySelector("[data-ctx-delete]") || document.createElement("button")

    this.onContext = (e) => {
      const row = e.target.closest && e.target.closest("[data-note-row]")
      if (!row) {
        // Not our surface: dismiss, and leave the native menu alone.
        this.hide()
        return
      }
      e.preventDefault()
      this.open(row, {x: e.clientX, y: e.clientY})
    }
    // Capture phase, so a click that opens another note still dismisses. It
    // also fires on the confirm modal's own buttons, which is what closes the
    // menu once the dialog has taken over naming the note being deleted.
    this.onAway = (e) => {
      if (!this.el.contains(e.target)) this.hide()
    }
    this.onKey = (e) => {
      if (e.key === "Escape") this.hide()
    }
    // One scroll of the rail and an anchored menu is pointing at a different
    // row, so it closes rather than lying about what it acts on.
    this.onScroll = () => this.hide()

    document.addEventListener("contextmenu", this.onContext)
    document.addEventListener("pointerdown", this.onAway, true)
    window.addEventListener("keydown", this.onKey)
    window.addEventListener("scroll", this.onScroll, true)
    window.addEventListener("resize", this.onScroll)

    // Only ever reached by the click `claw_confirm` re-dispatches after the
    // operator confirmed — the first click is stopped in the capture phase and
    // never bubbles here. Without this, confirming with the Enter key (which
    // needs no second pointerdown) would leave the menu open over a note that
    // no longer exists.
    this.item.addEventListener("click", () => this.hide())
  },

  destroyed() {
    document.removeEventListener("contextmenu", this.onContext)
    document.removeEventListener("pointerdown", this.onAway, true)
    window.removeEventListener("keydown", this.onKey)
    window.removeEventListener("scroll", this.onScroll, true)
    window.removeEventListener("resize", this.onScroll)
  },

  open(row, point) {
    const path = row.dataset.noteRow
    if (!path) {
      this.hide()
      return
    }

    this.item.setAttribute("phx-value-path", path)
    this.item.setAttribute(
      "data-claw-confirm",
      `Permanently delete "${path}"? This cannot be undone.`,
    )

    this.el.hidden = false
    this.place(point)
  },

  // `position: fixed` resolves against the nearest ancestor carrying a
  // transform / filter / backdrop-filter — NOT the viewport. The rail lives in
  // `.ic-panel`, which on the homepage has `backdrop-filter: blur(10px)`, so
  // viewport coordinates land somewhere around the middle of the screen.
  // Rather than hardcode which ancestor wins, park the element at 0,0 and
  // measure where that actually lands: the offset between the two is the
  // correction, whatever the containing block turns out to be.
  place(point) {
    const el = this.el
    el.style.left = "0px"
    el.style.top = "0px"
    const origin = el.getBoundingClientRect()

    const {x, y} = menuPosition({
      point,
      size: {width: origin.width, height: origin.height},
      viewport: {width: window.innerWidth, height: window.innerHeight},
    })

    el.style.left = `${x - origin.left}px`
    el.style.top = `${y - origin.top}px`
  },

  hide() {
    this.el.hidden = true
    // `phx-value-path` is deliberately left behind. The confirm modal's own
    // pointerdown dismisses this menu *before* the confirmed click is
    // re-dispatched at the item, and that click reads the attribute then.
  },
}

// Double-click the note's title to open the rename/move form.
//
// LiveView has no `phx-dblclick`, and a single click must stay inert: the title
// sits directly above the writing surface, so a stray click on the way to the
// text must not throw a form in the operator's face.
//
// ## Keyboard
//
// The `<h2>` keeps its heading role rather than becoming `role="button"` —
// pointer users get a gesture, screen-reader users keep the structure that
// tells them which note is open, and `role="button"` would trade the second for
// the first. It is `tabindex="0"` with `aria-keyshortcuts`, and Enter or F2
// while it is focused does what the double-click does: Enter is the list
// convention, F2 is the file-manager one, and neither costs anything here
// because the element has no other activation.
export const NoteTitle = {
  mounted() {
    // Element-scoped, so they are collected with the element; only the two
    // document-level listeners above need explicit removal.
    this.el.addEventListener("dblclick", (e) => {
      e.preventDefault()
      this.open()
    })
    this.el.addEventListener("keydown", (e) => {
      if (e.key !== "Enter" && e.key !== "F2") return
      e.preventDefault()
      this.open()
    })
  },

  // `pushEventTo(this.el, …)` rather than `pushEvent`: the handler belongs to
  // NotesComponent, and an untargeted event lands on StatusLive and crashes.
  open() {
    this.pushEventTo(this.el, "toggle_rename", {})
  },
}
