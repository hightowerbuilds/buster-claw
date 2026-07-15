// Home/End caret handling for text fields.
//
// macOS WKWebView quirk (Tauri shell): Home/End/PageUp/PageDown arrive as
// Apple function-key codepoints from the Private Use Area (End = U+F72B), and
// instead of moving the caret the webview INSERTS the character into the
// field — it renders as a tofu box (the "x in a box"). Nothing in the DOM
// asked for that; it's the webview's key-binding path leaking through.
//
// So we take the keys over entirely: on capture, compute the caret move
// ourselves and preventDefault so the webview never gets to insert anything.
// Applied unconditionally (not just under Tauri) so the dev browser behaves
// identically to the shipped app.
//
// Semantics (the cross-platform text-editing convention):
//   End         → end of the current logical line (`\n`-delimited)
//   Home        → start of the current logical line
//   Cmd/Ctrl +  → end / start of the whole value
//   Shift       → extend the selection instead of collapsing it
//   PageUp/Down → swallowed in fields (native path inserts tofu; there is
//                 nothing sensible to scroll inside a chat box)

// Pure caret math: returns {start, end, direction} for setSelectionRange,
// or null when the key isn't ours.
export function caretTarget(value, selStart, selEnd, key, mods = {}) {
  const {jump = false, shift = false} = mods

  let target
  switch (key) {
    case "End":
      target = jump ? value.length : lineEnd(value, selEnd)
      return shift
        ? {start: Math.min(selStart, target), end: target, direction: "forward"}
        : {start: target, end: target, direction: "none"}

    case "Home":
      target = jump ? 0 : lineStart(value, selStart)
      return shift
        ? {start: target, end: Math.max(selEnd, target), direction: "backward"}
        : {start: target, end: target, direction: "none"}

    default:
      return null
  }
}

export function lineStart(value, pos) {
  return value.lastIndexOf("\n", Math.max(pos - 1, 0)) + 1
}

export function lineEnd(value, pos) {
  const next = value.indexOf("\n", pos)
  return next === -1 ? value.length : next
}

const EDITABLE = new Set(["INPUT", "TEXTAREA"])
const SWALLOW = new Set(["PageUp", "PageDown"])

// DOM glue: one capture-phase listener covers every field on the page.
export function installCaretKeys(win = window) {
  win.addEventListener(
    "keydown",
    e => {
      const el = e.target
      if (!el || !EDITABLE.has(el.tagName)) return

      if (SWALLOW.has(e.key)) {
        e.preventDefault()
        return
      }

      // Fields like <input type="number"> have no selection API — let those be.
      if (typeof el.selectionStart !== "number") return

      const move = caretTarget(el.value, el.selectionStart, el.selectionEnd, e.key, {
        jump: e.metaKey || e.ctrlKey,
        shift: e.shiftKey,
      })
      if (!move) return

      e.preventDefault()
      el.setSelectionRange(move.start, move.end, move.direction)
    },
    true
  )
}
