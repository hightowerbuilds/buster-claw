import {expect, test, describe} from "bun:test"
import {formatChord, isSaveChord, notesIntent, shouldAnnounceDirty} from "./note_keys.js"

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

describe("notesIntent", () => {
  const key = (k, extra = {}) => ({key: k, ...extra})

  test("⌘P opens the switcher and ⌘N starts a note, open or not", () => {
    expect(notesIntent(key("p", {metaKey: true}), {switcherOpen: false})).toBe("switcher")
    expect(notesIntent(key("N", {ctrlKey: true}), {switcherOpen: true})).toBe("new")
  })

  test("⌘S is left to the editor hook, so it is never double-submitted", () => {
    expect(notesIntent(key("s", {metaKey: true}), {switcherOpen: false})).toBe(null)
  })

  test("navigation keys belong to the switcher only while it is open", () => {
    // Otherwise arrows and Enter would be stolen from the textarea.
    expect(notesIntent(key("ArrowDown"), {switcherOpen: false})).toBe(null)
    expect(notesIntent(key("Enter"), {switcherOpen: false})).toBe(null)
    expect(notesIntent(key("Escape"), {switcherOpen: false})).toBe(null)

    expect(notesIntent(key("ArrowDown"), {switcherOpen: true})).toBe("down")
    expect(notesIntent(key("ArrowUp"), {switcherOpen: true})).toBe("up")
    expect(notesIntent(key("Enter"), {switcherOpen: true})).toBe("select")
    expect(notesIntent(key("Escape"), {switcherOpen: true})).toBe("close")
  })

  test("ordinary typing is none of its business", () => {
    expect(notesIntent(key("a"), {switcherOpen: false})).toBe(null)
    expect(notesIntent(key("p"), {switcherOpen: true})).toBe(null)
    expect(notesIntent(null, {})).toBe(null)
    expect(notesIntent({}, {})).toBe(null)
  })
})

describe("formatChord", () => {
  test("the three universal chords, on either platform", () => {
    expect(formatChord({key: "b", metaKey: true})).toBe("bold")
    expect(formatChord({key: "i", ctrlKey: true})).toBe("italic")
    expect(formatChord({key: "k", metaKey: true})).toBe("link")
  })

  test("capitalization does not change the chord", () => {
    expect(formatChord({key: "B", metaKey: true, shiftKey: true})).toBe("bold")
  })

  test("bare letters type letters", () => {
    expect(formatChord({key: "b"})).toBe(null)
    expect(formatChord({key: "i"})).toBe(null)
  })

  test("⌘S stays the save chord and never formats", () => {
    expect(formatChord({key: "s", metaKey: true})).toBe(null)
  })

  test("alt-modified chords are left to the OS", () => {
    expect(formatChord({key: "b", metaKey: true, altKey: true})).toBe(null)
  })

  test("commands without a chord have none", () => {
    // Deliberate: eleven of the fourteen toolbar commands are click-only.
    for (const key of ["h", "1", "l", "o", "t", "q", "e", "r"]) {
      expect(formatChord({key, metaKey: true})).toBe(null)
    }
  })

  test("a missing or keyless event never claims a chord", () => {
    expect(formatChord(null)).toBe(null)
    expect(formatChord({metaKey: true})).toBe(null)
  })
})
