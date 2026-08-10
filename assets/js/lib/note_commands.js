// Toolbar actions, as string transforms.
//
// Every button in the Notes toolbar — and every formatting chord — is one pure
// function from `(text, selection, kind)` to `{text, selection}`. Nothing here
// touches the DOM, calls `document.execCommand`, or knows that a contenteditable
// exists.
//
// That is `daily-growth/archive/08-09-26-notes-editor.md` D5, and it is worth restating why: the editor's
// model is the Markdown string. A toolbar that manipulated the *view* would have
// to be re-derived back into Markdown, which is the conversion step D1 removed
// on purpose. Rewriting the string and re-rendering is both simpler and the only
// version that cannot lose bytes.
//
// Every action toggles. Pressing Bold on bold text unbolds it; pressing H2 on an
// H2 makes it a paragraph. A formatting button that only ever adds is a button
// that traps you.

import {decorate, lineIndexAt, lineStarts} from "./note_markdown.js"

// The inline pairs. Both sides are the same string, which is what lets one
// implementation serve all four.
const INLINE_MARKS = {bold: "**", italic: "*", strike: "~~", code: "`"}

// Fixed block prefixes. `ordered` is absent because its prefix counts.
const BLOCK_PREFIX = {
  h1: "# ",
  h2: "## ",
  h3: "### ",
  h4: "#### ",
  h5: "##### ",
  h6: "###### ",
  bullet: "- ",
  task: "- [ ] ",
  quote: "> ",
}

// Block prefixes as they appear in existing text, which is looser than what the
// buttons write: any of `-*+`, either `.` or `)`, an already-ticked checkbox.
// Stripping has to recognise all of it or a toggle would double the marker.
const STRIP = [
  {kind: "heading", re: /^([ \t]*)(#{1,6}[ \t]+)(.*)$/},
  {kind: "task", re: /^([ \t]*)([-*+][ \t]+\[[ xX]\][ \t]+)(.*)$/},
  {kind: "bullet", re: /^([ \t]*)([-*+][ \t]+)(.*)$/},
  {kind: "ordered", re: /^([ \t]*)(\d{1,9}[.)][ \t]+)(.*)$/},
  {kind: "quote", re: /^([ \t]*)(>[ \t]?)(.*)$/},
]

function clamp(value, low, high) {
  return Math.min(Math.max(value, low), high)
}

function normalize(selection, text) {
  const start = clamp(Math.trunc(selection?.start ?? 0), 0, text.length)
  const end = clamp(Math.trunc(selection?.end ?? start), 0, text.length)

  return start <= end ? {start, end} : {start: end, end: start}
}

// What block is this line already, and what is left when its marker comes off?
// A heading reports as `h1`..`h6` so a toggle can tell "already an H2" from
// "is some other heading".
function stripPrefix(line) {
  for (const {kind, re} of STRIP) {
    const match = re.exec(line)
    if (!match) continue

    const [, indent, prefix, body] = match
    const named = kind === "heading" ? `h${prefix.trim().length}` : kind

    return {indent, kind: named, body}
  }

  const indent = /^[ \t]*/.exec(line)[0]

  return {indent, kind: null, body: line.slice(indent.length)}
}

/**
 * Wrap, unwrap, or insert an inline pair — bold, italic, strikethrough, code.
 *
 * Three cases, and the middle one is the one people actually hit: markers can
 * sit *outside* the selection (you double-clicked the word inside `**word**`),
 * *inside* it (you dragged across the whole thing), or not exist yet.
 */
export function applyInline(text, selection, kind) {
  const src = String(text ?? "")
  const sel = normalize(selection, src)
  const mark = INLINE_MARKS[kind]

  if (!mark) return {text: src, selection: sel}

  const width = mark.length
  const selected = src.slice(sel.start, sel.end)

  // A neighbouring marker that is part of a LONGER run of the same character is
  // somebody else's. Without this, pressing Italic on the selected word inside
  // `**hello**` sees a `*` on each side, unwraps them, and silently demotes bold
  // to italic — where what was asked for was both.
  const runsOn = src[sel.start - width - 1] === mark[0] || src[sel.end + width] === mark[0]

  // Markers hug the selection from outside. Also covers an empty selection
  // parked between them, which is how "unbold from the caret" works.
  if (
    !runsOn &&
    src.slice(sel.start - width, sel.start) === mark &&
    src.slice(sel.end, sel.end + width) === mark
  ) {
    return {
      text: src.slice(0, sel.start - width) + selected + src.slice(sel.end + width),
      selection: {start: sel.start - width, end: sel.end - width},
    }
  }

  // The selection swallowed its own markers.
  if (
    selected.length >= width * 2 &&
    selected.startsWith(mark) &&
    selected.endsWith(mark)
  ) {
    const inner = selected.slice(width, selected.length - width)

    return {
      text: src.slice(0, sel.start) + inner + src.slice(sel.end),
      selection: {start: sel.start, end: sel.start + inner.length},
    }
  }

  return {
    text: src.slice(0, sel.start) + mark + selected + mark + src.slice(sel.end),
    selection: {start: sel.start + width, end: sel.end + width},
  }
}

/**
 * Set, change, or clear the block kind of every line the selection touches —
 * headings, bullets, numbered items, tasks, quotes.
 *
 * Toggling off requires *every* touched line to already be this kind. Mixed
 * selections therefore convert rather than clear, which is what a person means
 * by pressing Bullet on a half-bulleted paragraph.
 *
 * Pass `"paragraph"` to strip whatever is there.
 */
export function applyBlock(text, selection, kind) {
  const src = String(text ?? "")
  const sel = normalize(selection, src)
  const lines = src.split("\n")
  const starts = lineStarts(lines)

  const first = lineIndexAt(starts, sel.start)
  const last = lineIndexAt(starts, sel.end)

  const touched = []
  for (let i = first; i <= last; i += 1) touched.push(i)

  const stripped = touched.map((i) => stripPrefix(lines[i]))
  const already = stripped.every((s) => s.kind === kind)
  const target = kind === "paragraph" || already ? null : kind

  const next = [...lines]
  const deltas = new Map()
  let counter = 1

  touched.forEach((i, n) => {
    const {indent, body} = stripped[n]

    let prefix = ""
    if (target === "ordered") {
      prefix = `${counter}. `
      counter += 1
    } else if (target) {
      prefix = BLOCK_PREFIX[target] ?? ""
    }

    next[i] = indent + prefix + body
    deltas.set(i, next[i].length - lines[i].length)
  })

  const nextStarts = lineStarts(next)

  // A selection spanning lines is a line-wise selection, and it stays one: all
  // three lines were selected before the button, so all three are selected
  // after. Shifting each end by its own prefix delta would leave the first line
  // half-selected from just after its new `- `, which is nobody's intent.
  if (last > first) {
    return {
      text: next.join("\n"),
      selection: {start: nextStarts[first], end: nextStarts[last] + next[last].length},
    }
  }

  // Within one line the opposite is true: the caret belongs to a character, not
  // to a column, so it moves with the prefix that was inserted before it.
  const remap = (offset) => {
    const i = lineIndexAt(starts, offset)
    const column = offset - starts[i]
    const moved = clamp(column + (deltas.get(i) ?? 0), 0, next[i].length)

    return nextStarts[i] + moved
  }

  return {
    text: next.join("\n"),
    selection: {start: remap(sel.start), end: remap(sel.end)},
  }
}

/**
 * Wrap the selection as a link. The selection lands on the URL so the next
 * keystroke fills it in, which is the only ordering that makes an empty-URL
 * link useful rather than annoying.
 */
export function applyLink(text, selection, url = "") {
  const src = String(text ?? "")
  const sel = normalize(selection, src)
  const label = src.slice(sel.start, sel.end)
  const inserted = `[${label}](${url})`
  const urlStart = sel.start + label.length + 3

  return {
    text: src.slice(0, sel.start) + inserted + src.slice(sel.end),
    selection: {start: urlStart, end: urlStart + url.length},
  }
}

/**
 * The two block inserts that are not prefixes: a horizontal rule and a fenced
 * code block. Both must occupy whole lines of their own, so both are stated in
 * terms of lines rather than of the caret.
 */
export function insertBlock(text, selection, kind) {
  const src = String(text ?? "")
  const sel = normalize(selection, src)
  const lines = src.split("\n")
  const starts = lineStarts(lines)
  const first = lineIndexAt(starts, sel.start)
  const last = lineIndexAt(starts, sel.end)

  if (kind === "fence") {
    const body = lines.slice(first, last + 1)
    const next = [...lines.slice(0, first), "```", ...body, "```", ...lines.slice(last + 1)]
    // Caret onto the opening fence's language slot — the useful place to be.
    const caret = starts[first] + 3

    return {text: next.join("\n"), selection: {start: caret, end: caret}}
  }

  if (kind === "hr") {
    // A rule replaces a blank line rather than pushing one down; otherwise
    // pressing it on an empty paragraph leaves a stray gap above.
    const blank = lines[last].trim() === ""
    const head = lines.slice(0, blank ? last : last + 1)
    const next = [...head, "---", "", ...lines.slice(last + 1)]
    const caret = lineStarts(next)[head.length + 1]

    return {text: next.join("\n"), selection: {start: caret, end: caret}}
  }

  return {text: src, selection: sel}
}

/**
 * Tick or untick the task on the line at `offset`, leaving the caret where it
 * was. This is the checkbox click, and it is deliberately not `applyBlock`:
 * clicking a box means "change its state", never "stop being a task".
 */
export function toggleTask(text, offset) {
  const src = String(text ?? "")
  const lines = src.split("\n")
  const starts = lineStarts(lines)
  const index = lineIndexAt(starts, clamp(Math.trunc(offset ?? 0), 0, src.length))
  const match = /^([ \t]*[-*+][ \t]+\[)([ xX])(\][ \t]+.*)$/.exec(lines[index])

  if (!match) return {text: src, selection: {start: offset, end: offset}}

  lines[index] = `${match[1]}${match[2] === " " ? "x" : " "}${match[3]}`

  return {text: lines.join("\n"), selection: {start: offset, end: offset}}
}

/**
 * Which commands are already in force at `offset` — what the toolbar should show
 * as pressed.
 *
 * Both halves come from the tokenizer rather than from a second parser: the
 * block is the line's own block, and the inline styles are the styles of the
 * segment the caret is standing in. A toolbar computing this independently is
 * how a button starts disagreeing with the text under it.
 *
 * A caret *before* a marker is outside the span it opens — standing at the very
 * start of `**bold**` is not standing in bold, and pressing Bold there should
 * start a new one rather than claim to end this one.
 */
export function activeCommands(text, offset) {
  const src = String(text ?? "")
  const lines = src.split("\n")
  const starts = lineStarts(lines)
  const index = lineIndexAt(starts, clamp(Math.trunc(offset ?? 0), 0, src.length))
  const line = decorate(src)[index]

  if (!line) return []

  const active = new Set()
  const {block} = line

  if (block.kind === "heading") active.add(`h${block.level}`)
  else if (BLOCK_PREFIX[block.kind] || block.kind === "ordered") active.add(block.kind)

  const column = offset - starts[index]
  let seen = 0

  for (const segment of line.segments) {
    const end = seen + segment.text.length

    if (column > seen && column <= end) {
      for (const style of segment.styles) {
        if (INLINE_MARKS[style]) active.add(style)
      }
    }

    seen = end
  }

  return NOTE_COMMANDS.map((c) => c.cmd).filter((cmd) => active.has(cmd))
}

/**
 * The command table. Exported as data because the Elixir toolbar renders the
 * same set, and a lockstep test asserts the two agree — this repo's standing
 * answer to one list living in two languages.
 */
export const NOTE_COMMANDS = [
  {cmd: "h1", kind: "block", label: "Heading 1"},
  {cmd: "h2", kind: "block", label: "Heading 2"},
  {cmd: "h3", kind: "block", label: "Heading 3"},
  {cmd: "bold", kind: "inline", label: "Bold"},
  {cmd: "italic", kind: "inline", label: "Italic"},
  {cmd: "strike", kind: "inline", label: "Strikethrough"},
  {cmd: "code", kind: "inline", label: "Inline code"},
  {cmd: "link", kind: "link", label: "Link"},
  {cmd: "bullet", kind: "block", label: "Bulleted list"},
  {cmd: "ordered", kind: "block", label: "Numbered list"},
  {cmd: "task", kind: "block", label: "Task"},
  {cmd: "quote", kind: "block", label: "Quote"},
  {cmd: "fence", kind: "insert", label: "Code block"},
  {cmd: "hr", kind: "insert", label: "Divider"},
]

/**
 * Run a command by name. The hook's whole formatting path is this one call, so
 * the mapping from a button to a transform lives here rather than in a switch
 * inside a DOM listener.
 */
export function runCommand(cmd, text, selection) {
  const entry = NOTE_COMMANDS.find((c) => c.cmd === cmd)

  if (!entry) return {text: String(text ?? ""), selection: normalize(selection, String(text ?? ""))}

  switch (entry.kind) {
    case "inline":
      return applyInline(text, selection, cmd)
    case "block":
      return applyBlock(text, selection, cmd)
    case "insert":
      return insertBlock(text, selection, cmd)
    case "link":
      return applyLink(text, selection)
    default:
      return {text: String(text ?? ""), selection: normalize(selection, String(text ?? ""))}
  }
}
