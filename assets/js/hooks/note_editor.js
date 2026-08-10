// The Notes editor: a live-preview surface over a hidden textarea.
//
// ## The shape
//
//   model   the hidden <textarea>. Server-rendered, form-serialized, and the
//           only thing that reaches `save_note`.
//   view    the contenteditable `[data-note-surface]`, one <div> per line.
//
// The server contract is unchanged: writing the model and dispatching `input`
// fires the same `phx-change` on the same form with the same `phx-debounce`, so
// autosave, the revision check, the conflict banner and ⌘S work exactly as they
// did against a plain textarea (`daily-growth/archive/08-09-26-notes-editor.md` D4).
//
// ## The one rule: the browser owns editing
//
// **Typing never writes to the DOM tree.** Not one node. The browser inserts and
// deletes characters exactly as it would in a textarea, and this hook's entire
// job on a keystroke is to read the result out and hand it to the model.
//
// Enter, Backspace, Delete, arrow keys, selection, drag, autocorrect, IME,
// spellcheck and — crucially — ⌘Z are therefore the browser's own, and work
// because we are not fighting them.
//
// The two earlier designs both lost to this and are worth naming so nobody
// rebuilds them (W3, and Part VIII):
//
//   * Phase 1 replaced the focused line's element on every keystroke and
//     restored the caret by offset. Typing felt like it was catching.
//   * Phase 3 kept a parallel model — `docLines`, `decorated`, `rendered`,
//     `hot` — beside the DOM. Four things to keep in step per keystroke; one
//     stale `hot` index made an early return swallow edits, and backspace stopped
//     deleting.
//
// So: no mirror, no caret arithmetic on the typing path, no keystroke
// interception. There is nothing to fall out of sync because there is nothing
// to sync.
//
// ## Where DOM writes ARE allowed
//
// Three places, none of them on the typing path:
//
//   1. **Full render** — mount, or the server hands over different text.
//   2. **The caret leaves a line** — that line gets decorated. Safe precisely
//      because the caret is somewhere else by then, so nothing needs restoring.
//   3. **A toolbar command** — rare and deliberate, so it may re-render and
//      re-seat the caret.
//
// The line the caret IS in keeps whatever decoration it had when the caret
// arrived, and CSS reveals its markers (`data-hot`). Its decoration goes stale
// as you type — type `**` and it stays plain until you leave the line — and that
// staleness is the price of the rule above. It is a good trade.

import {isSaveChord, formatChord, shouldAnnounceDirty} from "../lib/note_keys.js"
import {decorateLine, lineIndexAt, lineStarts, serializeLines} from "../lib/note_markdown.js"
import {activeCommands, runCommand, toggleTask} from "../lib/note_commands.js"
import {documentHtml, lineAttributes, lineHtml} from "../lib/note_view.js"

// Slow on purpose. The focus check covers the case that actually matters (you
// were away and something changed); this only catches a second window on the
// same screen, and every tick is a stat plus a read.
const POLL_MS = 20000

export const NoteEditor = {
  mounted() {
    this.dirty = false
    this.hotLine = null
    this.lastText = null

    this.onInput = this.onInput.bind(this)
    this.onKeyDown = this.onKeyDown.bind(this)
    this.onClick = this.onClick.bind(this)
    this.onFocus = this.onFocus.bind(this)
    this.onPaste = this.onPaste.bind(this)
    this.onSelect = this.onSelect.bind(this)
    this.onMouseDown = this.onMouseDown.bind(this)

    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("keydown", this.onKeyDown)
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("paste", this.onPaste)
    this.el.addEventListener("mousedown", this.onMouseDown)
    window.addEventListener("focus", this.onFocus)
    // `selectionchange` fires only on the document, and it is the only event
    // that reports a caret moved by an arrow key or a click.
    document.addEventListener("selectionchange", this.onSelect)
    this.timer = setInterval(this.onFocus, POLL_MS)

    this.syncFromModel()
  },

  updated() {
    // The server re-rendered with its own idea of the save state. Anything but
    // "unsaved" means the draft is no longer ahead of it, so the next keystroke
    // gets to announce itself again.
    if (this.state() !== "unsaved") this.dirty = false

    this.syncFromModel()
  },

  destroyed() {
    clearInterval(this.timer)
    window.removeEventListener("focus", this.onFocus)
    document.removeEventListener("selectionchange", this.onSelect)
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("keydown", this.onKeyDown)
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("paste", this.onPaste)
    this.el.removeEventListener("mousedown", this.onMouseDown)
  },

  state() {
    return this.el.dataset.saveState
  },

  textarea() {
    return this.el.querySelector("textarea")
  },

  surface() {
    return this.el.querySelector("[data-note-surface]")
  },

  value() {
    const textarea = this.textarea()

    return textarea ? textarea.value : ""
  },

  lines() {
    const surface = this.surface()

    return surface ? Array.from(surface.children) : []
  },

  // ------------------------------------------------------------------ the model

  // Read the DOM and hand it to the model. Deliberately unconditional and
  // synchronous — no early return, no debounce, no "did the line I think is
  // focused change?" test. Every one of those is a way to drop an edit, and
  // dropping an edit is the bug this rewrite exists to remove. Reading
  // `textContent` off N elements is cheap; the network save is already debounced
  // by `phx-debounce` on the textarea.
  pushModel() {
    const textarea = this.textarea()
    const surface = this.surface()
    if (!textarea || !surface) return

    const text = serializeLines(surface.children)
    if (text === this.lastText) return

    textarea.value = text
    this.lastText = text

    if (shouldAnnounceDirty({dirty: this.dirty, state: this.state()})) {
      this.dirty = true
      this.pushEventTo(this.el, "note_dirty", {})
    }

    // Bubbles to the form, so `phx-change="save_note"` and its debounce fire
    // exactly as they would from a real textarea keystroke.
    textarea.dispatchEvent(new Event("input", {bubbles: true}))
  },

  // The server's bytes, whenever they differ from what is on screen: a note
  // switch, a reloaded disk version, a resolved conflict.
  //
  // The focus guard is the second half of the fix described in
  // `notes_component.ex`'s `assign_body/2`. That change stops the server echoing
  // a saved draft back; this refuses to act on one even if something starts
  // echoing again. Rebuilding the surface under a caret that is actively in it
  // destroys both the caret and anything typed during the round-trip, and no
  // legitimate server-side text change arrives while the user is typing —
  // opening a note, reloading the disk version and resolving a conflict are all
  // reached by clicking something, which moves focus off the surface first.
  syncFromModel() {
    const text = this.value()
    if (text === this.lastText) return

    const surface = this.surface()
    if (surface && surface.contains(document.activeElement)) return

    this.lastText = text
    this.render(text)
  },

  // ----------------------------------------------------------------- rendering

  // Blow the surface away and rebuild it. Only from `syncFromModel` and the
  // toolbar — never from a keystroke.
  render(text) {
    const surface = this.surface()
    if (!surface) return

    surface.innerHTML = documentHtml(text).join("")
    this.hotLine = null
  },

  // How many fences open before this line — the one piece of context a line
  // cannot read off itself. An odd count means the line is inside a code block,
  // where `# foo` is text rather than a heading.
  insideFence(line) {
    let open = 0

    for (let node = line.previousElementSibling; node; node = node.previousElementSibling) {
      if (node.dataset.block === "fence") open += 1
    }

    return open % 2 === 1
  },

  // Re-decorate a line and put it back. Callers must guarantee the caret is not
  // inside it — replacing an element the caret lives in is exactly what the two
  // previous designs did wrong.
  redecorate(line) {
    if (!line || !line.isConnected) return

    const index = this.lines().indexOf(line)
    if (index < 0) return

    const markup = lineHtml(decorateLine(line.textContent, this.insideFence(line)), index)
    if (line.outerHTML === markup) return

    line.outerHTML = markup
  },

  // ------------------------------------------------------------------- events

  // The typing path. Attributes and the model, nothing else.
  onInput(event) {
    // The hidden textarea's own event, dispatched by `pushModel`. Re-reading
    // here would be a loop.
    if (event.target === this.textarea()) return

    const surface = this.surface()
    if (!surface || !surface.contains(event.target)) return

    // Keep the current line's BLOCK styling live as you type, so `## ` grows
    // into a heading under the caret. Attributes only: setting an attribute
    // cannot disturb a selection inside the element, where touching its children
    // would.
    const line = this.caretLine()
    if (line) applyAttributes(line, decorateLine(line.textContent, this.insideFence(line)))

    this.pushModel()
  },

  // The caret moved. Two attribute writes and, if it left a line behind, one
  // re-decoration of that line.
  onSelect() {
    const line = this.caretLine()
    if (line === this.hotLine) return

    const left = this.hotLine
    this.hotLine = line

    if (left && left.isConnected) {
      left.removeAttribute("data-hot")
      // The caret is on a different line now, so rebuilding this one is safe.
      this.redecorate(left)
    }

    if (line) line.setAttribute("data-hot", "")

    this.paintToolbar()
  },

  // The line element the caret is in, or null when the caret is not in the
  // surface at all.
  caretLine() {
    const selection = window.getSelection()
    if (!selection || selection.rangeCount === 0) return null

    const surface = this.surface()
    const node = selection.getRangeAt(0).startContainer
    if (!surface || !surface.contains(node)) return null

    const element = node instanceof Element ? node : node.parentElement

    return element ? element.closest("[data-line]") : null
  },

  onKeyDown(event) {
    if (isSaveChord(event)) {
      const form = this.el.querySelector("form[data-note-editor]")
      if (!form) return

      event.preventDefault()
      form.requestSubmit()

      return
    }

    if (!this.surface()?.contains(event.target)) return

    const chord = formatChord(event)
    if (!chord) return

    event.preventDefault()
    this.runCommand(chord)
  },

  onPaste(event) {
    if (!this.surface()?.contains(event.target)) return

    const text = event.clipboardData?.getData("text/plain")
    if (text === undefined || text === null) return

    // Plain text only — the clipboard's HTML flavour would have to be converted
    // into Markdown, which is the lossy step this editor exists to not have.
    //
    // `insertText` rather than a manual splice: it is the browser's own
    // insertion, so it lands in the native undo stack and needs no caret work.
    // Deprecated, universally supported, and the only API that does this.
    event.preventDefault()
    document.execCommand("insertText", false, text.replace(/\r\n?/g, "\n"))
    this.pushModel()
  },

  // A toolbar button must not take focus: the selection it is about to format
  // lives in the contenteditable, and clicking anything focusable collapses it.
  // Cancelling `mousedown` is what keeps "select a word, press Bold" working —
  // by `click` the selection would already be gone.
  onMouseDown(event) {
    if (event.target.closest("[data-note-cmd]")) event.preventDefault()
  },

  onClick(event) {
    const copy = event.target.closest("[data-note-copy-draft]")
    if (copy) {
      event.preventDefault()
      this.copyDraft(copy)

      return
    }

    const command = event.target.closest("[data-note-cmd]")
    if (command) {
      event.preventDefault()
      this.runCommand(command.dataset.noteCmd)

      return
    }

    if (!this.surface()?.contains(event.target)) return

    const task = event.target.closest('[data-block="task"] .nm')
    if (task) {
      event.preventDefault()
      this.applyEdit(toggleTask(this.value(), this.offsetOfLine(task.closest("[data-line]"))))

      return
    }

    const wiki = event.target.closest(".n-wiki[data-target]")
    if (wiki) {
      event.preventDefault()
      // Resolution is the server's: it owns the vault index and the fuzzy
      // matching, and duplicating either here is how two sources of truth start.
      this.pushEventTo(this.el, "follow_link", {target: wiki.dataset.target})
    }
  },

  // ---------------------------------------------------------------- commands

  // The one path that may rebuild the surface and move the caret, because it is
  // the one the user asked for explicitly.
  runCommand(cmd) {
    const surface = this.surface()
    if (!surface) return

    surface.focus()
    this.applyEdit(runCommand(cmd, this.value(), this.selectionRange() || {start: 0, end: 0}))
  },

  applyEdit({text, selection}) {
    const textarea = this.textarea()
    if (!textarea) return

    textarea.value = text
    this.lastText = null
    this.render(text)
    this.selectRange(selection)
    this.pushModel()
    this.onSelect()
    this.paintToolbar()
  },

  // Which buttons look pressed. Derived from the caret rather than tracked as
  // state, so it cannot drift out of step with the text underneath it.
  paintToolbar() {
    const range = this.selectionRange()
    const active = new Set(range ? activeCommands(this.value(), range.start) : [])

    for (const button of this.el.querySelectorAll("[data-note-cmd]")) {
      const on = active.has(button.dataset.noteCmd)

      button.toggleAttribute("data-active", on)
      button.setAttribute("aria-pressed", String(on))
    }
  },

  // ------------------------------------------------------------------- caret
  //
  // Used ONLY by the toolbar path. Nothing on the typing path calls any of this,
  // which is the point.

  starts() {
    return lineStarts(this.lines().map((el) => el.textContent))
  },

  offsetOfLine(line) {
    const index = this.lines().indexOf(line)

    return index < 0 ? 0 : this.starts()[index]
  },

  offsetOf(node, nodeOffset) {
    const element = node instanceof Element ? node : node?.parentElement
    const line = element ? element.closest("[data-line]") : null
    if (!line) return null

    const index = this.lines().indexOf(line)
    if (index < 0) return null

    return this.starts()[index] + withinLine(line, node, nodeOffset)
  },

  selectionRange() {
    const selection = window.getSelection()
    if (!selection || selection.rangeCount === 0) return null

    const range = selection.getRangeAt(0)
    const surface = this.surface()
    if (!surface || !surface.contains(range.startContainer)) return null

    const start = this.offsetOf(range.startContainer, range.startOffset)
    const end = this.offsetOf(range.endContainer, range.endOffset)
    if (start === null || end === null) return null

    return start <= end ? {start, end} : {start: end, end: start}
  },

  selectRange({start, end}) {
    const lines = this.lines()
    if (lines.length === 0) return

    const starts = this.starts()
    const from = spotAt(lines, starts, start)
    const to = start === end ? from : spotAt(lines, starts, end)
    if (!from || !to) return

    const range = document.createRange()
    range.setStart(from.node, from.offset)
    range.setEnd(to.node, to.offset)

    const selection = window.getSelection()
    selection.removeAllRanges()
    selection.addRange(range)
  },

  // ------------------------------------------------------------------- misc

  onFocus() {
    if (this.el.dataset.notePath) this.pushEventTo(this.el, "check_revision", {})
  },

  // execCommand is the fallback rather than the primary: the async clipboard API
  // is the one that works when the page is not the focused document, which is
  // exactly the situation a conflict tends to arrive in.
  copyDraft(button) {
    const text = this.value()

    const done = () => {
      const original = button.dataset.noteCopyDraft || button.textContent
      button.dataset.noteCopyDraft = original
      button.textContent = "Copied"
      setTimeout(() => {
        button.textContent = original
      }, 1500)
    }

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, () => this.copyByTextarea(text, done))
    } else {
      this.copyByTextarea(text, done)
    }
  },

  copyByTextarea(text, done) {
    const textarea = this.textarea()
    if (!textarea) return

    textarea.select()
    try {
      if (document.execCommand("copy")) done()
    } catch (_error) {
      // Nothing left to try; the draft is still on screen and still on disk-safe
      // hold, which is the guarantee that actually matters.
    }
  },
}

// Set the block attributes a line's decoration implies, removing the ones it
// does not. Attributes only — never children — because this runs mid-keystroke
// with the caret inside the element.
function applyAttributes(element, decorated) {
  for (const [name, value] of Object.entries(lineAttributes(decorated))) {
    if (value === null || value === undefined) element.removeAttribute(name)
    else element.setAttribute(name, String(value))
  }
}

// The character offset of a DOM position within one line element. `node` may be
// the line itself, in which case `nodeOffset` counts child nodes rather than
// characters — the shape a collapsed selection in an empty line arrives as.
function withinLine(line, node, nodeOffset) {
  if (node === line) {
    let total = 0

    for (let i = 0; i < nodeOffset && i < line.childNodes.length; i += 1) {
      total += line.childNodes[i].textContent.length
    }

    return total
  }

  const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT)
  let total = 0

  while (walker.nextNode()) {
    if (walker.currentNode === node) return total + nodeOffset

    total += walker.currentNode.textContent.length
  }

  return total
}

// The inverse: an absolute offset as a text node and an offset inside it.
function spotAt(lines, starts, offset) {
  const index = lineIndexAt(starts, offset)
  const line = lines[index]
  if (!line) return null

  const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT)
  let remaining = Math.max(0, offset - starts[index])
  let last = null

  while (walker.nextNode()) {
    const node = walker.currentNode
    last = node

    if (remaining <= node.textContent.length) return {node, offset: remaining}

    remaining -= node.textContent.length
  }

  // An empty line is a lone <br> with no text node; address the element itself.
  return last ? {node: last, offset: last.textContent.length} : {node: line, offset: 0}
}
