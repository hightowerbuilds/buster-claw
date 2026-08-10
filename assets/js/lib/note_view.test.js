import {expect, test, describe} from "bun:test"
import {documentHtml, escapeHtml, lineHtml} from "./note_view.js"
import {decorate} from "./note_markdown.js"

const render = (text) => documentHtml(text).join("\n")

// The text a browser would show for a rendered line: markup stripped, entities
// resolved. Stands in for `textContent`, which is what the real save path reads.
const textOf = (html) =>
  html
    .replace(/<br>/g, "")
    .replace(/<[^>]*>/g, "")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&")

describe("escapeHtml", () => {
  test("it escapes every character that can break out of markup or an attribute", () => {
    expect(escapeHtml(`<img src=x onerror="alert('x')">`)).toBe(
      "&lt;img src=x onerror=&quot;alert(&#39;x&#39;)&quot;&gt;",
    )
  })

  test("ampersands are escaped first, so escapes do not escape each other", () => {
    expect(escapeHtml("&lt;")).toBe("&amp;lt;")
  })

  test("it survives nothing", () => {
    expect(escapeHtml(null)).toBe("")
    expect(escapeHtml("")).toBe("")
  })
})

describe("a note cannot inject markup", () => {
  // A note may be agent-authored, pasted, or fetched. Its text is text.
  const attacks = [
    "<script>alert(1)</script>",
    '<img src=x onerror="alert(1)">',
    "# <script>alert(1)</script>",
    "**<iframe src=evil>**",
    "[click](javascript:alert(1))",
    '[[Target" onmouseover="alert(1)]]',
    "`<script>alert(1)</script>`",
    "- [ ] <svg onload=alert(1)>",
  ]

  // Strip the tags this module writes itself. Anything angle-bracketed left over
  // came from the document, which would mean it had escaped into markup.
  const withoutOurTags = (html) =>
    html.replace(/<\/?(?:div|span)\b[^>]*>/g, "").replace(/<br>/g, "")

  test("the only markup in the output is the markup this module wrote", () => {
    for (const attack of attacks) {
      const leftover = withoutOurTags(render(attack))

      expect(leftover).not.toContain("<")
      expect(leftover).not.toContain(">")
    }
  })

  test("a quote in a link target cannot break out of its attribute", () => {
    // The one injection the tag check above cannot see: an unescaped `"` would
    // end `data-target` and start a new attribute, with no angle bracket in
    // sight.
    const html = render('[[Target" onmouseover="alert(1)]]')

    expect(html).toContain("&quot;")
    expect(html).not.toContain('" onmouseover="')
  })

  test("and the text still round-trips to exactly what the file said", () => {
    for (const attack of attacks) {
      expect(textOf(render(attack))).toBe(attack)
    }
  })
})

describe("the rendered text is the file's text", () => {
  const document = [
    "# Launch plan",
    "",
    "Ship the **beta** by _Friday_.",
    "",
    "- [ ] sign the cert",
    "- [x] book the room",
    "",
    "> quoted, with a [[Wiki Link]] and a [link](https://x.dev)",
    "",
    "```elixir",
    "# not a heading",
    "```",
    "",
    "| a | b |",
    "| - | - |",
  ].join("\n")

  test("stripping the markup gives the document back, byte for byte", () => {
    // The same invariant `note_markdown` asserts, now measured through the view:
    // whatever the view puts on screen is what the save path will read out of it.
    expect(textOf(render(document))).toBe(document)
  })

  test("including a trailing newline, which is a byte like any other", () => {
    expect(textOf(render("one\n"))).toBe("one\n")
    expect(documentHtml("one\n")).toHaveLength(2)
  })
})

describe("lineHtml", () => {
  const one = (line) => documentHtml(line)[0]

  test("the block facts land on the element for CSS to read", () => {
    expect(one("## Launch")).toContain('data-block="heading"')
    expect(one("## Launch")).toContain('data-level="2"')
    expect(one("  - buy")).toContain('data-block="bullet"')
    expect(one("  - buy")).toContain('data-depth="1"')
  })

  test("a task reports its tick, so the box can be drawn either way", () => {
    expect(one("- [ ] todo")).toContain('data-checked="false"')
    expect(one("- [x] done")).toContain('data-checked="true"')
  })

  test("markers are spans that still hold their characters", () => {
    // Hidden by CSS, present in the DOM. The whole design rests on this.
    expect(one("## Launch")).toContain('<span class="nm n-heading">## </span>')
  })

  test("unstyled prose gets no element at all", () => {
    expect(one("just prose")).toBe('<div class="nl" data-line="0" data-block="paragraph">just prose</div>')
  })

  test("an empty line gets a br so it can be clicked into", () => {
    expect(one("")).toContain("<br>")
    // …and the br cannot reach the file.
    expect(textOf(one(""))).toBe("")
  })

  test("a link's target rides along for the click handler", () => {
    expect(one("[docs](https://x.dev)")).toContain('data-target="https://x.dev"')
    expect(one("[[Launch]]")).toContain('data-target="Launch"')
  })

  test("the index is on the element, so a click can find its line", () => {
    expect(documentHtml("a\nb\nc")[2]).toContain('data-line="2"')
  })
})

describe("data-hot belongs to the hook, not to this module", () => {
  // The version of this block that shipped first asserted "nothing depends on
  // where the caret is" by calling `documentHtml` twice with no caret argument
  // and comparing the results. It passed for the whole time the code did the
  // opposite, because neither call ever exercised the thing it named. It is
  // rewritten here to assert the property directly — and it is the third
  // vacuous guard this one feature has produced, which is a rate worth noticing.

  test("no rendered line carries data-hot", () => {
    // The hook sets and clears it as an ATTRIBUTE as the caret moves. An
    // attribute write cannot disturb a selection inside the element; rebuilding
    // the element can, and doing that on the line the caret is standing in is
    // what cost this feature two rewrites.
    expect(documentHtml("# One\ntwo\n- three").join("")).not.toContain("data-hot")
    expect(lineHtml(decorate("# One")[0], 0)).not.toContain("data-hot")
  })

  test("a third argument cannot change the output", () => {
    // Guards the property from the other side: if a `hot` parameter ever comes
    // back, this fails rather than silently rendering two ways again.
    //
    // Asserting `lineHtml.length === 2` would NOT do it — a parameter with a
    // default does not count toward `Function.length`, so `hot = false` would
    // slip straight past. Comparing the outputs is the assertion that bites.
    expect(lineHtml(decorate("## H")[0], 0, true)).toBe(lineHtml(decorate("## H")[0], 0))
  })

  test("a line renders exactly one way, and it is the decorated way", () => {
    const html = documentHtml("## Launch **plan**")[0]

    expect(html).toContain('<span class="nm n-heading">## </span>')
    expect(html).toContain("n-bold")
  })
})
