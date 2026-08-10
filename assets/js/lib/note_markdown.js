// Markdown → decorations, for the Notes live-preview editor.
//
// This module answers exactly one question: *given a line of Markdown, which
// runs of it are markers and which are content, and what is this line?* It has
// no opinion about the DOM, does not touch it, and never converts anything.
//
// ## The invariant everything rests on
//
// **The segments of a line concatenate back to that line, byte for byte.** No
// segment is dropped, added, reordered, or rewritten — a marker is *labelled*,
// not removed. The view hides markers with CSS; the text underneath is still the
// file's own bytes.
//
// That is what makes an unrecognised construct safe. A table, a footnote, raw
// HTML, YAML frontmatter — anything this tokenizer does not model comes back as
// one plain segment and saves back identical. The tokenizer can only ever fail
// to *style* something; it cannot fail to *preserve* it. `noteMarkdownHolds` is
// that invariant as a callable assertion, and the test suite runs it over every
// fixture rather than trusting the individual cases.
//
// See `daily-growth/archive/08-09-26-notes-editor.md` D1 for why the editor is
// built on decoration rather than on a rendered document converted back.

// A fence line — ``` or ~~~ — opens or closes a code block, and its own text is
// entirely marker. Tracked across lines by `decorate`, because a line inside a
// fence must not be tokenized at all: `# not a heading` is code in there.
const FENCE = /^[ \t]*(?:```|~~~)/

// A horizontal rule. Checked before the list matchers: `- - -` is a rule, and
// the bullet matcher would otherwise claim it.
const HR = /^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$/

// Block openers. Order matters where two can match the same line: TASK before
// BULLET (`- [ ] x` is both), HR before either.
const HEADING = /^(#{1,6}[ \t]+)(.*)$/
const TASK = /^([ \t]*[-*+][ \t]+\[([ xX])\][ \t]+)(.*)$/
const BULLET = /^([ \t]*[-*+][ \t]+)(.*)$/
const ORDERED = /^([ \t]*\d{1,9}[.)][ \t]+)(.*)$/
const QUOTE = /^([ \t]*>[ \t]?)(.*)$/

// Inline spans, in precedence order. Each captures (open, content, close) in
// groups 1-3 so one builder handles them all; `nest` says whether the content is
// itself tokenized. Code never nests — backticks mean "this is literal".
//
// `**` must precede `*` and `__` must precede `_`, or bold would tokenize as two
// empty italics. The italic patterns exclude their own marker from the content
// for the same reason.
//
// `notBeforeWord` is on the single underscore alone, and it is measured against
// `Earmark` — the renderer this app actually uses — not against CommonMark:
//
//     un_der_score     stays plain     (closing _ is followed by a letter)
//     foo_bar_ baz     emphasises      (opening _ being intraword is fine)
//     a__b__c          emphasises      (__ carries no such rule)
//     a*b*c            emphasises      (* carries no such rule)
//
// Without it, every `snake_case_identifier` in a note would show up italic in
// the editor and plain everywhere the file is rendered. Where the tokenizer and
// Earmark disagree elsewhere the file is still safe — the invariant above holds
// regardless — so this chases the one divergence that is common enough to
// notice, not full parity with a parser.
const SPANS = [
  {kind: "code", re: /^(`)([^`\n]+)(`)/, nest: false},
  {kind: "strike", re: /^(~~)([^\n]+?)(~~)/, nest: true},
  {kind: "bold", re: /^(\*\*)([^\n]+?)(\*\*)/, nest: true},
  {kind: "bold", re: /^(__)([^\n]+?)(__)/, nest: true},
  {kind: "italic", re: /^(\*)([^*\n]+)(\*)/, nest: true},
  {kind: "italic", re: /^(_)([^_\n]+)(_)/, nest: true, notBeforeWord: true},
]

const WORD = /[\p{L}\p{N}]/u

// `[[Target]]` and `[[Target|Label]]`. The label is what a reader wants to see,
// so everything up to and including the pipe is marker.
const WIKI = /^\[\[([^\]\n|]+?)(?:\|([^\]\n]*))?\]\]/

// `[label](url)`. The URL is marker: it is addressing, not prose.
const LINK = /^\[([^\]\n]*)\]\(([^)\n]*)\)/

function segment(text, styles = [], marker = false, target = null) {
  return {text, styles, marker, target}
}

// Push a style onto a segment produced by a nested pass, so `**bold _and_
// italic**` reports both on the inner run.
function under(kind) {
  return (seg) => ({...seg, styles: [kind, ...seg.styles]})
}

function spanSegments(kind, open, content, close, nest) {
  const inner = nest ? inlineSegments(content) : [segment(content, [])]

  return [
    segment(open, [kind], true),
    ...inner.map(under(kind)),
    segment(close, [kind], true),
  ]
}

// Try every matcher at the head of `rest`. Returns the segments it produced and
// how many characters they consumed, or null when nothing matches here.
function matchSpan(rest) {
  const wiki = WIKI.exec(rest)

  if (wiki) {
    const [whole, target, label] = wiki
    // With a label, the target hides inside the opening marker; without one, the
    // target *is* the visible text.
    const open = label === undefined ? "[[" : `[[${target}|`
    const shown = label === undefined ? target : label

    return {
      length: whole.length,
      segments: [
        segment(open, ["wiki"], true),
        segment(shown, ["wiki"], false, target),
        segment("]]", ["wiki"], true),
      ],
    }
  }

  const link = LINK.exec(rest)

  if (link) {
    const [whole, label, url] = link

    return {
      length: whole.length,
      segments: [
        segment("[", ["link"], true),
        segment(label, ["link"], false, url),
        segment(`](${url})`, ["link"], true),
      ],
    }
  }

  for (const {kind, re, nest, notBeforeWord} of SPANS) {
    const match = re.exec(rest)
    if (!match) continue
    if (notBeforeWord && WORD.test(rest[match[0].length] ?? "")) continue

    return {
      length: match[0].length,
      segments: spanSegments(kind, match[1], match[2], match[3], nest),
    }
  }

  return null
}

// Walk the text once, accumulating unmatched characters into a plain run and
// flushing it whenever a span starts. One character at a time on a miss is the
// slow-but-correct scan; a line is short and this runs per keystroke on one line.
function inlineSegments(text) {
  const out = []
  let plain = ""
  let index = 0

  while (index < text.length) {
    const hit = matchSpan(text.slice(index))

    if (!hit) {
      plain += text[index]
      index += 1
      continue
    }

    if (plain) {
      out.push(segment(plain, []))
      plain = ""
    }

    out.push(...hit.segments)
    index += hit.length
  }

  if (plain) out.push(segment(plain, []))

  return out
}

// Indentation is part of a list marker, so the view can indent with padding
// instead of with spaces the caret has to walk through.
function depthOf(marker) {
  const indent = /^[ \t]*/.exec(marker)[0]

  return Math.floor(indent.replace(/\t/g, "  ").length / 2)
}

function blockOf(line) {
  if (HR.test(line)) return {block: {kind: "hr"}, marker: line, body: ""}

  const heading = HEADING.exec(line)
  if (heading) {
    const level = heading[1].trim().length

    return {block: {kind: "heading", level}, marker: heading[1], body: heading[2]}
  }

  const task = TASK.exec(line)
  if (task) {
    return {
      block: {kind: "task", checked: task[2] !== " ", depth: depthOf(task[1])},
      marker: task[1],
      body: task[3],
    }
  }

  const bullet = BULLET.exec(line)
  if (bullet) {
    return {block: {kind: "bullet", depth: depthOf(bullet[1])}, marker: bullet[1], body: bullet[2]}
  }

  const ordered = ORDERED.exec(line)
  if (ordered) {
    return {
      block: {kind: "ordered", depth: depthOf(ordered[1])},
      marker: ordered[1],
      body: ordered[2],
    }
  }

  const quote = QUOTE.exec(line)
  if (quote) {
    return {block: {kind: "quote", depth: depthOf(quote[1])}, marker: quote[1], body: quote[2]}
  }

  return {block: {kind: "paragraph"}, marker: "", body: line}
}

/**
 * Decorate one line. `inFence` comes from `decorate`, which is the only thing
 * that can know it — fences are the one construct a line cannot self-report.
 *
 * Returns `{block, segments, fence}` where `fence` means "this line toggles the
 * code-block state".
 */
export function decorateLine(line, inFence = false) {
  const text = String(line ?? "")

  if (FENCE.test(text)) {
    return {block: {kind: "fence"}, segments: [segment(text, ["fence"], true)], fence: true}
  }

  // Inside a fence nothing is markup, including the leading whitespace that
  // would otherwise read as a list indent.
  if (inFence) {
    return {block: {kind: "code"}, segments: text ? [segment(text, ["fence"])] : [], fence: false}
  }

  const {block, marker, body} = blockOf(text)

  const segments = [
    ...(marker ? [segment(marker, [block.kind], true)] : []),
    // An `hr` has no body and a `code` line has no spans; everything else gets
    // the inline pass over what follows its marker.
    ...(block.kind === "hr" ? [] : inlineSegments(body)),
  ]

  return {block, segments, fence: false}
}

/**
 * Decorate a whole document. Returns one entry per line — including the trailing
 * empty one a document ending in a newline produces, because dropping it would
 * lose a byte on the next save.
 */
export function decorate(text) {
  let inFence = false

  return String(text ?? "")
    .split("\n")
    .map((line) => {
      const decorated = decorateLine(line, inFence)
      if (decorated.fence) inFence = !inFence

      return decorated
    })
}

/**
 * The character offset at which each line begins, counting the `\n` between
 * them. Shared with `note_commands.js` and the editor hook: everything in this
 * feature addresses text as one absolute offset, and this is what turns that
 * into a (line, column) and back.
 */
export function lineStarts(lines) {
  const starts = []
  let offset = 0

  for (const line of lines) {
    starts.push(offset)
    offset += line.length + 1
  }

  return starts
}

/** Which line contains `offset`. Clamped at both ends rather than returning -1. */
export function lineIndexAt(starts, offset) {
  for (let i = starts.length - 1; i >= 0; i -= 1) {
    if (offset >= starts[i]) return i
  }

  return 0
}

/**
 * Read the editor's text back out of its line elements.
 *
 * **`textContent`, never `innerText`.** `innerText` returns the *rendered* text,
 * so every marker this editor hides with CSS would be absent from it — the file
 * would silently lose its `##` and its `**` on the next save. `textContent`
 * ignores CSS entirely, which is the only reason this design is safe.
 *
 * It also does not insert newlines at element boundaries, which is why this
 * joins the lines itself rather than reading the container in one call.
 */
export function serializeLines(lineEls) {
  return Array.from(lineEls ?? [])
    .map((el) => el.textContent ?? "")
    .join("\n")
}

/**
 * The invariant, as an assertion: do this line's segments reconstruct it?
 *
 * Exported because the test suite runs it over every fixture, and because a
 * future tokenizer change that breaks preservation should fail loudly here
 * rather than quietly in someone's vault.
 */
export function noteMarkdownHolds(line, inFence = false) {
  const {segments} = decorateLine(line, inFence)

  return segments.map((s) => s.text).join("") === String(line ?? "")
}
