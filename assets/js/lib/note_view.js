// Decorations → HTML, for the Notes live-preview editor.
//
// One line of Markdown becomes one line element. The element carries the block
// facts as data attributes (`data-block`, `data-level`, `data-depth`,
// `data-checked`) and CSS does the rest, so "what a heading looks like" lives in
// `app.css` and not in here.
//
// ## Markers are hidden by CSS, never by omission
//
// Every marker run is emitted as a `<span class="nm">` holding its real
// characters. `app.css` hides those spans, and reveals them again on the line
// the caret is in (`data-hot`). The text is always present in the DOM, which is
// what lets `serializeLines` read the file back with `textContent` and get the
// bytes the file actually had.
//
// **`data-hot` is not rendered here.** The hook sets and clears it as an
// attribute as the caret moves, because an attribute write cannot disturb a
// selection inside the element while rebuilding the element would. This module
// renders one line one way, and never needs to know where the caret is.
//
// ## Escaping
//
// This module builds markup from note text, and a note may be agent-authored or
// pasted from anywhere. `<img onerror=…>` in a note must be *text*. Everything
// that comes from the document goes through `escapeHtml`; the only unescaped
// characters in the output are the ones this file writes itself.

import {decorate} from "./note_markdown.js"

const ESCAPES = {"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}

/**
 * Escape text for insertion into markup, attribute values included.
 *
 * `&` first, or the escapes would escape each other's ampersands. Quotes are
 * covered because segment targets become attribute values.
 */
export function escapeHtml(text) {
  return String(text ?? "").replace(/[&<>"']/g, (char) => ESCAPES[char])
}

function attrs(pairs) {
  return Object.entries(pairs)
    .filter(([, value]) => value !== null && value !== undefined && value !== false)
    .map(([name, value]) => ` ${name}="${escapeHtml(value)}"`)
    .join("")
}

function segmentHtml(segment) {
  const text = escapeHtml(segment.text)

  // Unstyled prose is the common case and needs no element at all — fewer nodes
  // to build per keystroke, and fewer boundaries for the caret to sit inside.
  if (!segment.marker && segment.styles.length === 0) return text

  const classes = [segment.marker ? "nm" : "ns", ...segment.styles.map((s) => `n-${s}`)]

  return `<span${attrs({class: classes.join(" "), "data-target": segment.target})}>${text}</span>`
}

/**
 * Render one decorated line to its element markup.
 *
 * An empty line still gets a `<br>`: a contenteditable child with no content
 * collapses to zero height, and a blank paragraph you cannot click into is not a
 * blank paragraph. `<br>` contributes nothing to `textContent`, so it cannot
 * reach the file.
 */
export function lineHtml(decorated, index) {
  const open = `<div${attrs({class: "nl", "data-line": index, ...lineAttributes(decorated)})}>`
  const inner = decorated.segments.map(segmentHtml).join("")

  return `${open}${inner || "<br>"}</div>`
}

/**
 * The block facts as attributes, so CSS can read them and the hook can update
 * them in place.
 *
 * Separated from `lineHtml` because the hot path needs exactly this and nothing
 * else: when a keystroke turns a paragraph into a heading, the editor sets these
 * four attributes on the existing element rather than rebuilding it. Touching an
 * attribute does not disturb the caret inside the element; replacing the element
 * does.
 */
export function lineAttributes({block}) {
  return {
    "data-block": block.kind,
    "data-level": block.level ?? null,
    "data-depth": block.depth ?? null,
    "data-checked": block.checked === undefined ? null : String(block.checked),
  }
}

/** Render a whole document to one markup string per line. */
export function documentHtml(text) {
  return decorate(text).map(lineHtml)
}
