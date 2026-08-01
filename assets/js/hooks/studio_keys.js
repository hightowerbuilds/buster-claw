// Keyboard shortcuts for the Studio arranger (SOUND_STUDIO_ROADMAP Phase 7).
//
// ⌘Z / ⌘⇧Z undo and redo, ⌘C / ⌘V copy and paste a clip, ⌫ removes the selected
// one. All five push to the parent LiveView, because selection, clipboard, and
// the undo stacks all live in `StatusLive` — the arranger component is
// discarded on every tab switch, and an undo history that evaporates when you
// glance at Chat reads as the feature being broken.
//
// ## Scoping, which is the whole difficulty
//
// These are OS-level chords. Two guards keep them from stealing anything:
//
//   1. The hook is mounted inside the Studio panel, which only exists while
//      that tab is open — so nothing is bound anywhere else in the app.
//   2. Typing contexts are excluded. ⌘Z inside the "New track…" field must undo
//      your typing, not your arrangement; ⌘C in the source picker must copy
//      text. The music player's Space handling makes the same exclusion for the
//      same reason, including xterm's helper textarea.
//
// Copy and paste are only intercepted when a clip is actually selected and,
// for paste, when the clipboard holds something. Otherwise the event is left
// alone so the browser's own copy/paste still works over ordinary page text.

import {isTypingContext} from "../lib/keys.js"

export const StudioKeys = {
  mounted() {
    this.onKeyDown = this.onKeyDown.bind(this)
    window.addEventListener("keydown", this.onKeyDown)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeyDown)
  },

  hasSelection() {
    return this.el.dataset.clipSelected === "true"
  },

  hasClipboard() {
    return this.el.dataset.clipboard === "true"
  },

  onKeyDown(event) {
    if (isTypingContext(event.target)) return

    const mod = event.metaKey || event.ctrlKey
    const key = event.key.toLowerCase()

    if (mod && key === "z") {
      event.preventDefault()
      this.pushEvent(event.shiftKey ? "studio_redo" : "studio_undo", {})
      return
    }

    // Ctrl+Y is the Windows/Linux redo; harmless to accept alongside ⇧⌘Z.
    if (mod && key === "y") {
      event.preventDefault()
      this.pushEvent("studio_redo", {})
      return
    }

    if (mod && key === "c" && this.hasSelection()) {
      event.preventDefault()
      this.pushEvent("studio_copy", {})
      return
    }

    if (mod && key === "v" && this.hasClipboard()) {
      event.preventDefault()
      this.pushEvent("studio_paste", {})
      return
    }

    // Backspace would otherwise navigate back in some webviews, so this one is
    // prevented whenever it would act.
    if ((key === "backspace" || key === "delete") && !mod && this.hasSelection()) {
      event.preventDefault()
      this.pushEvent("studio_delete_clip", {})
    }
  },
}
