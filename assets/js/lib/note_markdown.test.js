import {expect, test, describe} from "bun:test"
import {decorate, decorateLine, noteMarkdownHolds, serializeLines} from "./note_markdown.js"

// Everything the tokenizer might meet, including the things it deliberately does
// not model. The preservation suite runs over all of it.
const FIXTURES = [
  "",
  "   ",
  "plain prose",
  "# Heading one",
  "###### Heading six",
  "####### seven hashes is not a heading",
  "#nospace",
  "## Launch **plan** for _Friday_",
  "- bullet",
  "  - nested bullet",
  "* star bullet",
  "+ plus bullet",
  "1. ordered",
  "12) also ordered",
  "- [ ] unticked",
  "- [x] ticked",
  "- [X] shouty tick",
  "> quoted",
  ">no space quote",
  "---",
  "- - -",
  "***",
  "___",
  "`code span`",
  "**bold**",
  "__also bold__",
  "*italic*",
  "_also italic_",
  "~~struck~~",
  "**bold with _italic_ inside**",
  "`**not bold inside code**`",
  "[[Wiki Target]]",
  "[[Projects/Launch|the launch note]]",
  "[label](https://example.com)",
  "[](https://example.com)",
  "a **b** c _d_ e `f` g",
  "unclosed **bold",
  "unclosed `code",
  "stray ] bracket ) paren",
  "| a | b |",
  "| - | - |",
  "<div>raw html</div>",
  "---\ntitle: frontmatter\n---",
  "term\n: definition",
  "footnote[^1]",
  "emoji 🐈 and ünïcødé",
  "trailing spaces   ",
  "\ttab indented",
  "100% * 3 * 4",
  "snake_case_word_here",
  "a_b_c_d_e",
]

describe("the preservation invariant", () => {
  test("every fixture's segments concatenate back to the line, byte for byte", () => {
    for (const fixture of FIXTURES) {
      for (const line of fixture.split("\n")) {
        expect(noteMarkdownHolds(line)).toBe(true)
      }
    }
  })

  test("it holds inside a fence too, where nothing is markup", () => {
    for (const fixture of FIXTURES) {
      for (const line of fixture.split("\n")) {
        expect(noteMarkdownHolds(line, true)).toBe(true)
      }
    }
  })

  test("a whole document round-trips through decorate", () => {
    // The property that actually matters: what the view will hold is what the
    // file said. Trailing newline included — dropping it would lose a byte.
    const doc = FIXTURES.join("\n") + "\n"
    const rebuilt = decorate(doc)
      .map((line) => line.segments.map((s) => s.text).join(""))
      .join("\n")

    expect(rebuilt).toBe(doc)
  })
})

describe("blocks", () => {
  const block = (line, inFence = false) => decorateLine(line, inFence).block

  test("headings report their level", () => {
    expect(block("# one")).toEqual({kind: "heading", level: 1})
    expect(block("### three")).toEqual({kind: "heading", level: 3})
    expect(block("###### six")).toEqual({kind: "heading", level: 6})
  })

  test("seven hashes and a missing space are prose, as Markdown says", () => {
    expect(block("####### seven").kind).toBe("paragraph")
    expect(block("#nospace").kind).toBe("paragraph")
  })

  test("a task is a task before it is a bullet", () => {
    expect(block("- [ ] todo")).toEqual({kind: "task", checked: false, depth: 0})
    expect(block("- [x] done")).toEqual({kind: "task", checked: true, depth: 0})
    expect(block("- [X] done")).toEqual({kind: "task", checked: true, depth: 0})
  })

  test("a rule is a rule before it is a bullet", () => {
    // `- - -` matches the bullet pattern too; order decides.
    expect(block("---").kind).toBe("hr")
    expect(block("- - -").kind).toBe("hr")
    expect(block("***").kind).toBe("hr")
    expect(block("___").kind).toBe("hr")
  })

  test("indentation becomes a depth so the view can indent without spaces", () => {
    expect(block("- top").depth).toBe(0)
    expect(block("  - one in").depth).toBe(1)
    expect(block("    - two in").depth).toBe(2)
    expect(block("\t- a tab counts as two").depth).toBe(1)
  })

  test("ordered lists take either delimiter", () => {
    expect(block("1. a").kind).toBe("ordered")
    expect(block("12) b").kind).toBe("ordered")
  })

  test("quotes tolerate a missing space", () => {
    expect(block("> quoted").kind).toBe("quote")
    expect(block(">quoted").kind).toBe("quote")
  })
})

describe("the block marker is marked, and it is exactly the marker", () => {
  const first = (line) => decorateLine(line).segments[0]

  test("a heading hides its hashes and the space after them", () => {
    expect(first("## Launch")).toMatchObject({text: "## ", marker: true})
  })

  test("a task hides the whole checkbox, which the view redraws", () => {
    expect(first("- [ ] sign the cert")).toMatchObject({text: "- [ ] ", marker: true})
  })

  test("a rule is marker end to end — it has no content", () => {
    const {segments} = decorateLine("---")

    expect(segments).toHaveLength(1)
    expect(segments[0]).toMatchObject({text: "---", marker: true})
  })

  test("a paragraph has no marker segment at all", () => {
    expect(first("just prose")).toMatchObject({text: "just prose", marker: false})
  })
})

describe("inline spans", () => {
  const shown = (line) =>
    decorateLine(line)
      .segments.filter((s) => !s.marker)
      .map((s) => s.text)
      .join("")

  const styled = (line, kind) =>
    decorateLine(line)
      .segments.filter((s) => !s.marker && s.styles.includes(kind))
      .map((s) => s.text)

  test("what a reader sees is the text without its markers", () => {
    expect(shown("a **b** c")).toBe("a b c")
    expect(shown("## a `b` c")).toBe("a b c")
    expect(shown("- [ ] buy ~~milk~~ bread")).toBe("buy milk bread")
  })

  test("bold beats italic, so ** is never two empty italics", () => {
    expect(styled("**bold**", "bold")).toEqual(["bold"])
    expect(styled("**bold**", "italic")).toEqual([])
    expect(styled("__bold__", "bold")).toEqual(["bold"])
  })

  test("italic still works on its own", () => {
    expect(styled("*it*", "italic")).toEqual(["it"])
    expect(styled("_it_", "italic")).toEqual(["it"])
  })

  test("styles nest", () => {
    expect(styled("**bold with _italic_ inside**", "italic")).toEqual(["italic"])
    expect(styled("**bold with _italic_ inside**", "bold")).toEqual([
      "bold with ",
      "italic",
      " inside",
    ])
  })

  test("code does not nest — backticks mean literal", () => {
    expect(styled("`**not bold**`", "code")).toEqual(["**not bold**"])
    expect(styled("`**not bold**`", "bold")).toEqual([])
  })

  // These four are measured against Earmark, the renderer this app uses, so the
  // editor predicts what the file will actually look like. See the SPANS note.
  test("an identifier with underscores stays plain", () => {
    expect(styled("snake_case_word", "italic")).toEqual([])
    expect(styled("a_b_c_d_e", "italic")).toEqual([])
    expect(styled("un_der_score", "italic")).toEqual([])
  })

  test("but a closer followed by a space still emphasises, even opening intraword", () => {
    expect(styled("foo_bar_ baz", "italic")).toEqual(["bar"])
    expect(styled("_x_.", "italic")).toEqual(["x"])
  })

  test("the rule is the single underscore's alone", () => {
    expect(styled("a__b__c", "bold")).toEqual(["b"])
    expect(styled("a*b*c", "italic")).toEqual(["b"])
  })

  test("an unclosed marker is just text", () => {
    expect(shown("unclosed **bold")).toBe("unclosed **bold")
    expect(styled("unclosed **bold", "bold")).toEqual([])
  })
})

describe("links", () => {
  const segs = (line) => decorateLine(line).segments

  test("a wiki link shows its target when it has no label", () => {
    expect(segs("[[Launch]]")).toEqual([
      {text: "[[", styles: ["wiki"], marker: true, target: null},
      {text: "Launch", styles: ["wiki"], marker: false, target: "Launch"},
      {text: "]]", styles: ["wiki"], marker: true, target: null},
    ])
  })

  test("a labelled wiki link hides the target inside the opening marker", () => {
    const [open, label] = segs("[[Projects/Launch|the launch]]")

    expect(open).toMatchObject({text: "[[Projects/Launch|", marker: true})
    expect(label).toMatchObject({text: "the launch", marker: false, target: "Projects/Launch"})
  })

  // This guarantee used to live in `Links.replace/2` and was asserted through
  // the Notes preview's HTML. The preview is gone; the guarantee moved here.
  // A note *about* wiki links will contain one inside a fence, and turning that
  // sample into a link would corrupt the thing it exists to show.
  test("a wiki link inside code is not a link", () => {
    const fenced = decorateLine("[[Fenced]]", true)

    expect(fenced.segments).toHaveLength(1)
    expect(fenced.segments[0].target).toBe(null)
    expect(fenced.segments[0].styles).not.toContain("wiki")

    const spanned = decorateLine("`[[Spanned]]` and [[Live]]")
    const targets = spanned.segments.filter((s) => s.target).map((s) => s.target)

    expect(targets).toEqual(["Live"])
  })

  test("an inline link hides its URL and carries it as the target", () => {
    const [open, label, close] = segs("[docs](https://example.com)")

    expect(open).toMatchObject({text: "[", marker: true})
    expect(label).toMatchObject({text: "docs", target: "https://example.com"})
    expect(close).toMatchObject({text: "](https://example.com)", marker: true})
  })
})

describe("fences", () => {
  test("a fence line toggles the state and is all marker", () => {
    const opened = decorateLine("```elixir")

    expect(opened.fence).toBe(true)
    expect(opened.block.kind).toBe("fence")
    expect(opened.segments[0].marker).toBe(true)
  })

  test("inside a fence nothing is markup", () => {
    const line = decorateLine("# not a heading **not bold**", true)

    expect(line.block.kind).toBe("code")
    expect(line.segments).toHaveLength(1)
    expect(line.segments[0]).toMatchObject({text: "# not a heading **not bold**", marker: false})
  })

  test("decorate carries the fence state across lines and closes it again", () => {
    const kinds = decorate("# real\n```\n# fake\n```\n# real again").map((l) => l.block.kind)

    expect(kinds).toEqual(["heading", "fence", "code", "fence", "heading"])
  })

  test("indentation inside a fence is code, not a list", () => {
    expect(decorateLine("  - not a bullet", true).block.kind).toBe("code")
  })
})

describe("serializeLines", () => {
  test("it joins line elements with newlines", () => {
    const els = [{textContent: "# One"}, {textContent: ""}, {textContent: "two"}]

    expect(serializeLines(els)).toBe("# One\n\ntwo")
  })

  test("it reads textContent, so CSS-hidden markers survive the save", () => {
    // The whole design rests on this. `innerText` would return "One" here and
    // the file would silently lose its hashes.
    const el = {textContent: "# One", innerText: "One"}

    expect(serializeLines([el])).toBe("# One")
  })

  test("a missing or empty collection is an empty document, not a crash", () => {
    expect(serializeLines([])).toBe("")
    expect(serializeLines(null)).toBe("")
  })
})
