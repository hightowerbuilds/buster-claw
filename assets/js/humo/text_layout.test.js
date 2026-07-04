import {describe, expect, test} from "bun:test"
import {layoutLines, layoutPage} from "./text_layout.js"

// Stub measure: 10px per character (including joining spaces).
const measure = (s) => s.length * 10

describe("layoutLines", () => {
  test("wraps when a joined line would exceed maxWidth", () => {
    // "aaaa bbbb" = 90px > 80 → wrap; "bbbb cccc" = 90px > 80 → wrap again.
    expect(layoutLines(measure, ["aaaa", "bbbb", "cccc"], 80)).toEqual([
      "aaaa",
      "bbbb",
      "cccc",
    ])
  })

  test("packs words while they fit", () => {
    expect(layoutLines(measure, ["aa", "bb", "cc"], 80)).toEqual(["aa bb cc"])
  })

  test("a single overlong word still lands on its own line", () => {
    expect(layoutLines(measure, ["tiny", "enormousword"], 50)).toEqual([
      "tiny",
      "enormousword",
    ])
  })

  test("empty input yields no lines", () => {
    expect(layoutLines(measure, [], 100)).toEqual([])
  })
})

describe("layoutPage", () => {
  test("fits while the wrap stays within maxLines", () => {
    // Each "aaaa" word is 40px; maxWidth 80 packs one per line ("aaaa aaaa" = 90).
    const {lines, fits} = layoutPage(measure, ["aaaa", "aaaa"], 80, 2)
    expect(lines.length).toBe(2)
    expect(fits).toBe(true)
  })

  test("stops fitting when one more word would need an extra line", () => {
    expect(layoutPage(measure, ["aaaa", "aaaa", "aaaa"], 80, 2).fits).toBe(false)
  })

  test("an empty page always fits", () => {
    expect(layoutPage(measure, [], 80, 1)).toEqual({lines: [], fits: true})
  })
})
