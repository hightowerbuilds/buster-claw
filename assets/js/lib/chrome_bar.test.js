// bun test — the bookmark row's keyboard contract for suggestion chips.
import {describe, expect, test} from "bun:test"
import {suggestionStep} from "./chrome_bar.js"

describe("suggestionStep", () => {
  test("down and Tab move forward, up and shift-Tab move back", () => {
    expect(suggestionStep("ArrowDown", false)).toBe(1)
    expect(suggestionStep("Tab", false)).toBe(1)
    expect(suggestionStep("ArrowUp", false)).toBe(-1)
    expect(suggestionStep("Tab", true)).toBe(-1)
  })

  test("Escape restores the bookmarks", () => {
    expect(suggestionStep("Escape", false)).toBe("close")
  })

  test("every other key belongs to the address bar", () => {
    expect(suggestionStep("Enter", false)).toBe(0)
    expect(suggestionStep("a", false)).toBe(0)
    expect(suggestionStep("ArrowLeft", true)).toBe(0)
  })
})
