// bun test — pure-logic tests for Home/End caret math.
// Run: bun test assets/js/lib/ (from the repo root)
import {describe, expect, test} from "bun:test"
import {caretTarget, lineStart, lineEnd} from "./caret_keys.js"

const TEXT = "first line\nsecond line\nthird"

describe("line boundaries", () => {
  test("single-line value", () => {
    expect(lineStart("hello", 3)).toBe(0)
    expect(lineEnd("hello", 3)).toBe(5)
  })

  test("middle line of a multiline value", () => {
    // caret inside "second line" (position 14)
    expect(lineStart(TEXT, 14)).toBe(11)
    expect(lineEnd(TEXT, 14)).toBe(22)
  })

  test("caret exactly at a line start / end", () => {
    expect(lineStart(TEXT, 11)).toBe(11)
    expect(lineEnd(TEXT, 22)).toBe(22)
    // at position 0
    expect(lineStart(TEXT, 0)).toBe(0)
  })
})

describe("caretTarget End", () => {
  test("collapses the caret to end of the current line", () => {
    expect(caretTarget(TEXT, 14, 14, "End")).toEqual({start: 22, end: 22, direction: "none"})
  })

  test("end of the last (unterminated) line is the value end", () => {
    expect(caretTarget(TEXT, 25, 25, "End")).toEqual({start: 28, end: 28, direction: "none"})
  })

  test("cmd/ctrl jumps to the end of the whole value", () => {
    expect(caretTarget(TEXT, 3, 3, "End", {jump: true})).toEqual({
      start: 28,
      end: 28,
      direction: "none",
    })
  })

  test("shift extends the selection forward", () => {
    expect(caretTarget(TEXT, 12, 14, "End", {shift: true})).toEqual({
      start: 12,
      end: 22,
      direction: "forward",
    })
  })

  test("empty value is a no-op move to 0", () => {
    expect(caretTarget("", 0, 0, "End")).toEqual({start: 0, end: 0, direction: "none"})
  })
})

describe("caretTarget Home", () => {
  test("collapses the caret to start of the current line", () => {
    expect(caretTarget(TEXT, 14, 14, "Home")).toEqual({start: 11, end: 11, direction: "none"})
  })

  test("cmd/ctrl jumps to the start of the whole value", () => {
    expect(caretTarget(TEXT, 14, 14, "Home", {jump: true})).toEqual({
      start: 0,
      end: 0,
      direction: "none",
    })
  })

  test("shift extends the selection backward", () => {
    expect(caretTarget(TEXT, 14, 16, "Home", {shift: true})).toEqual({
      start: 11,
      end: 16,
      direction: "backward",
    })
  })
})

describe("other keys", () => {
  test("are not ours", () => {
    expect(caretTarget(TEXT, 3, 3, "ArrowLeft")).toBeNull()
    expect(caretTarget(TEXT, 3, 3, "a")).toBeNull()
    expect(caretTarget(TEXT, 3, 3, "Enter")).toBeNull()
  })
})
