import {expect, test, describe} from "bun:test"
import {isSaveChord, shouldAnnounceDirty} from "./note_keys.js"

describe("isSaveChord", () => {
  test("⌘S and Ctrl+S both save", () => {
    expect(isSaveChord({key: "s", metaKey: true})).toBe(true)
    expect(isSaveChord({key: "s", ctrlKey: true})).toBe(true)
  })

  test("capitalization does not change the chord", () => {
    // Caps Lock, or Shift held from the previous word.
    expect(isSaveChord({key: "S", metaKey: true, shiftKey: true})).toBe(true)
  })

  test("a bare s types an s", () => {
    expect(isSaveChord({key: "s"})).toBe(false)
  })

  test("other modified keys are none of its business", () => {
    expect(isSaveChord({key: "a", metaKey: true})).toBe(false)
    expect(isSaveChord({key: "Enter", ctrlKey: true})).toBe(false)
  })

  test("a missing or keyless event never claims the chord", () => {
    expect(isSaveChord(null)).toBe(false)
    expect(isSaveChord({metaKey: true})).toBe(false)
  })
})

describe("shouldAnnounceDirty", () => {
  test("the first keystroke on a clean note announces", () => {
    expect(shouldAnnounceDirty({dirty: false, state: "saved"})).toBe(true)
  })

  test("an already-dirty editor stays quiet", () => {
    expect(shouldAnnounceDirty({dirty: true, state: "unsaved"})).toBe(false)
  })

  test("a conflict halts the announcement, because autosave has stopped", () => {
    expect(shouldAnnounceDirty({dirty: false, state: "conflict"})).toBe(false)
  })

  test("a freshly opened note announces on its first edit", () => {
    expect(shouldAnnounceDirty({dirty: false, state: "idle"})).toBe(true)
  })
})
