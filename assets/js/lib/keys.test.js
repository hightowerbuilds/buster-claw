import {expect, test, describe} from "bun:test"
import {isTypingContext} from "./keys.js"

const el = (tagName, extra = {}) => ({tagName, ...extra})

describe("isTypingContext", () => {
  test("text entry is never a shortcut's business", () => {
    // ⌘Z in the New track field must undo TYPING, not the arrangement.
    expect(isTypingContext(el("INPUT"))).toBe(true)
    expect(isTypingContext(el("TEXTAREA"))).toBe(true)
  })

  test("select counts — typing a letter there jumps to an option", () => {
    expect(isTypingContext(el("SELECT"))).toBe(true)
  })

  test("contenteditable counts, being neither input nor textarea", () => {
    expect(isTypingContext(el("DIV", {isContentEditable: true}))).toBe(true)
  })

  test("ordinary elements are fair game", () => {
    expect(isTypingContext(el("DIV"))).toBe(false)
    expect(isTypingContext(el("BUTTON"))).toBe(false)
    expect(isTypingContext(el("BODY"))).toBe(false)
    expect(isTypingContext(el("DIV", {isContentEditable: false}))).toBe(false)
  })

  test("a missing target is not a typing context", () => {
    // Some synthetic events arrive without one; treating that as "typing" would
    // silently disable every shortcut.
    expect(isTypingContext(null)).toBe(false)
    expect(isTypingContext(undefined)).toBe(false)
  })
})
