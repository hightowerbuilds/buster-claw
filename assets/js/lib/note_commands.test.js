import {expect, test, describe} from "bun:test"
import {
  NOTE_COMMANDS,
  activeCommands,
  applyBlock,
  applyInline,
  applyLink,
  insertBlock,
  runCommand,
  toggleTask,
} from "./note_commands.js"

// Reads a case as "text with the selection marked by |…|", which is the only way
// these stay legible — every one of them is really about where the caret ends up.
function pick(marked) {
  const start = marked.indexOf("|")
  const end = marked.indexOf("|", start + 1) - 1

  return {text: marked.replace(/\|/g, ""), selection: {start, end}}
}

function mark({text, selection}) {
  return (
    text.slice(0, selection.start) +
    "|" +
    text.slice(selection.start, selection.end) +
    "|" +
    text.slice(selection.end)
  )
}

const inline = (marked, kind) => mark(applyInline(...Object.values(pick(marked)), kind))
const block = (marked, kind) => mark(applyBlock(...Object.values(pick(marked)), kind))

describe("applyInline", () => {
  test("it wraps the selection and keeps it selected", () => {
    expect(inline("say |hello| there", "bold")).toBe("say **|hello|** there")
    expect(inline("say |hello| there", "italic")).toBe("say *|hello|* there")
    expect(inline("say |hello| there", "code")).toBe("say `|hello|` there")
    expect(inline("say |hello| there", "strike")).toBe("say ~~|hello|~~ there")
  })

  test("an empty selection inserts the pair and parks the caret inside", () => {
    expect(inline("say || there", "bold")).toBe("say **||** there")
  })

  test("it unwraps when the markers hug the selection from outside", () => {
    // Double-clicking a word inside **word** selects the word, not the stars.
    expect(inline("say **|hello|** there", "bold")).toBe("say |hello| there")
  })

  test("it unwraps when the selection swallowed the markers", () => {
    // Dragging across the whole thing selects the stars too.
    expect(inline("say |**hello**| there", "bold")).toBe("say |hello| there")
  })

  test("an empty selection parked between markers unformats from the caret", () => {
    expect(inline("say **||** there", "bold")).toBe("say || there")
  })

  test("bold and italic compose rather than fight", () => {
    // The `*` on each side belongs to the `**`; italic must add, not steal it.
    expect(inline("say **|hello|** there", "italic")).toBe("say ***|hello|*** there")
  })

  test("bold still unwraps its own markers next to prose", () => {
    // The same guard must not make unwrapping impossible.
    expect(inline("say **|hello|** there", "bold")).toBe("say |hello| there")
    expect(inline("a *|b|* c", "italic")).toBe("a |b| c")
  })

  test("an unknown kind is a no-op, not a crash", () => {
    expect(inline("say |hello| there", "rainbow")).toBe("say |hello| there")
  })
})

describe("applyBlock", () => {
  test("it sets a prefix and moves the caret with the text", () => {
    expect(block("|Launch| plan", "h2")).toBe("## |Launch| plan")
    expect(block("|buy| milk", "bullet")).toBe("- |buy| milk")
    expect(block("|buy| milk", "task")).toBe("- [ ] |buy| milk")
    expect(block("|said| so", "quote")).toBe("> |said| so")
  })

  test("pressing the same block again clears it", () => {
    expect(block("## |Launch| plan", "h2")).toBe("|Launch| plan")
    expect(block("- |buy| milk", "bullet")).toBe("|buy| milk")
    expect(block("- [ ] |buy| milk", "task")).toBe("|buy| milk")
  })

  test("pressing a different block converts rather than stacks", () => {
    expect(block("## |Launch|", "h3")).toBe("### |Launch|")
    expect(block("- |buy|", "ordered")).toBe("1. |buy|")
    expect(block("- [ ] |buy|", "bullet")).toBe("- |buy|")
  })

  test("paragraph strips whatever is there", () => {
    expect(block("### |Launch|", "paragraph")).toBe("|Launch|")
    expect(block("> |said|", "paragraph")).toBe("|said|")
  })

  test("it strips the loose forms a person actually typed", () => {
    // The buttons write `- ` and `1. `; a note may hold any of these.
    expect(block("* |buy|", "paragraph")).toBe("|buy|")
    expect(block("+ |buy|", "paragraph")).toBe("|buy|")
    expect(block("12) |buy|", "paragraph")).toBe("|buy|")
    expect(block("- [X] |buy|", "paragraph")).toBe("|buy|")
    expect(block(">|said|", "paragraph")).toBe("|said|")
  })

  test("indentation survives, so a nested item stays nested", () => {
    expect(block("  - |buy|", "task")).toBe("  - [ ] |buy|")
  })

  test("a multi-line selection takes every line it touches", () => {
    expect(block("|one\ntwo\nthree|", "bullet")).toBe("|- one\n- two\n- three|")
  })

  test("numbering counts across the selection", () => {
    expect(block("|one\ntwo\nthree|", "ordered")).toBe("|1. one\n2. two\n3. three|")
  })

  test("a mixed selection converts rather than clears", () => {
    // Only an all-bullets selection is a toggle-off; this one is half-done, and
    // "finish the job" is what pressing Bullet means there.
    expect(block("|- one\ntwo|", "bullet")).toBe("|- one\n- two|")
  })

  test("an all-matching selection is the toggle-off", () => {
    expect(block("|- one\n- two|", "bullet")).toBe("|one\ntwo|")
  })

  test("lines after the edit keep their offsets", () => {
    const {text, selection} = applyBlock("one\ntwo\nthree", {start: 0, end: 0}, "h1")

    expect(text).toBe("# one\ntwo\nthree")
    expect(selection).toEqual({start: 2, end: 2})
  })

  test("an empty line can still become a list item", () => {
    expect(block("||", "bullet")).toBe("- ||")
  })
})

describe("applyLink", () => {
  test("it wraps the selection and selects the empty URL", () => {
    expect(mark(applyLink("see docs now", {start: 4, end: 8}))).toBe("see [docs](||) now")
  })

  test("a given URL comes back selected, ready to replace", () => {
    const {text, selection} = applyLink("see docs now", {start: 4, end: 8}, "https://x.dev")

    expect(text).toBe("see [docs](https://x.dev) now")
    expect(text.slice(selection.start, selection.end)).toBe("https://x.dev")
  })

  test("an empty selection still gives a usable skeleton", () => {
    expect(mark(applyLink("see  now", {start: 4, end: 4}))).toBe("see [](||) now")
  })
})

describe("insertBlock", () => {
  test("a fence wraps the touched lines", () => {
    const {text} = insertBlock("keep\nme\nsafe", {start: 5, end: 7}, "fence")

    expect(text).toBe("keep\n```\nme\n```\nsafe")
  })

  test("the caret lands on the opening fence's language slot", () => {
    const {text, selection} = insertBlock("me", {start: 0, end: 2}, "fence")

    expect(text).toBe("```\nme\n```")
    expect(selection).toEqual({start: 3, end: 3})
  })

  test("a rule on a blank line replaces it rather than pushing it down", () => {
    const {text} = insertBlock("above\n\nbelow", {start: 6, end: 6}, "hr")

    expect(text).toBe("above\n---\n\nbelow")
  })

  test("a rule after prose gets its own line", () => {
    const {text} = insertBlock("above\nbelow", {start: 3, end: 3}, "hr")

    expect(text).toBe("above\n---\n\nbelow")
  })

  test("an unknown kind is a no-op", () => {
    const {text} = insertBlock("keep me", {start: 0, end: 0}, "sparkles")

    expect(text).toBe("keep me")
  })
})

describe("toggleTask", () => {
  test("it ticks and unticks, leaving the caret alone", () => {
    expect(toggleTask("- [ ] buy milk", 9).text).toBe("- [x] buy milk")
    expect(toggleTask("- [x] buy milk", 9).text).toBe("- [ ] buy milk")
    expect(toggleTask("- [X] buy milk", 9).text).toBe("- [ ] buy milk")
  })

  test("it finds the line the offset is on, not the first one", () => {
    const {text} = toggleTask("- [ ] one\n- [ ] two", 15)

    expect(text).toBe("- [ ] one\n- [x] two")
  })

  test("a line that is not a task is left exactly as it is", () => {
    // Clicking a box means "change its state", never "become a task".
    expect(toggleTask("just prose", 2).text).toBe("just prose")
    expect(toggleTask("- a bullet", 2).text).toBe("- a bullet")
  })
})

describe("runCommand", () => {
  test("every advertised command does something and preserves the rest", () => {
    for (const {cmd} of NOTE_COMMANDS) {
      const {text, selection} = runCommand(cmd, "one\ntwo", {start: 0, end: 3})

      expect(typeof text).toBe("string")
      expect(text).toContain("two")
      expect(selection.start).toBeGreaterThanOrEqual(0)
      expect(selection.end).toBeLessThanOrEqual(text.length)
    }
  })

  test("it routes each kind to its transform", () => {
    expect(runCommand("bold", "hi", {start: 0, end: 2}).text).toBe("**hi**")
    expect(runCommand("h2", "hi", {start: 0, end: 2}).text).toBe("## hi")
    expect(runCommand("hr", "hi", {start: 2, end: 2}).text).toBe("hi\n---\n")
    expect(runCommand("link", "hi", {start: 0, end: 2}).text).toBe("[hi]()")
  })

  test("an unknown command changes nothing", () => {
    expect(runCommand("sparkles", "hi", {start: 0, end: 2}).text).toBe("hi")
  })

  test("the command table has no duplicates and every entry is routable", () => {
    const names = NOTE_COMMANDS.map((c) => c.cmd)
    const kinds = new Set(NOTE_COMMANDS.map((c) => c.kind))

    expect(new Set(names).size).toBe(names.length)
    expect([...kinds].sort()).toEqual(["block", "inline", "insert", "link"])
  })
})

describe("activeCommands", () => {
  const at = (marked) => {
    const offset = marked.indexOf("|")

    return activeCommands(marked.replace("|", ""), offset)
  }

  test("the caret's line reports its block", () => {
    expect(at("## Lau|nch")).toEqual(["h2"])
    expect(at("- bu|y milk")).toEqual(["bullet"])
    expect(at("1. fir|st")).toEqual(["ordered"])
    expect(at("- [ ] to|do")).toEqual(["task"])
    expect(at("> sai|d so")).toEqual(["quote"])
    expect(at("just pr|ose")).toEqual([])
  })

  test("the caret's span reports its inline styles", () => {
    expect(at("a **bo|ld** c")).toEqual(["bold"])
    expect(at("a *it|alic* c")).toEqual(["italic"])
    expect(at("a `co|de` c")).toEqual(["code"])
    expect(at("a ~~st|ruck~~ c")).toEqual(["strike"])
  })

  test("block and inline compose, in table order", () => {
    expect(at("## Ship the **be|ta**")).toEqual(["h2", "bold"])
  })

  test("nesting reports both", () => {
    expect(at("**bold with _ital|ic_ inside**")).toEqual(["bold", "italic"])
  })

  test("standing before a marker is standing outside the span", () => {
    // Pressing Bold here should start a new one, not claim to end this one.
    expect(at("|**bold**")).toEqual([])
    expect(at("a |**bold**")).toEqual([])
  })

  test("standing just inside the opening marker is inside the span", () => {
    expect(at("**|bold**")).toEqual(["bold"])
  })

  test("every name it returns is a real command", () => {
    const names = NOTE_COMMANDS.map((c) => c.cmd)
    const sample = "# H\n- [ ] t\n> q\n**b** *i* `c` ~~s~~\n1. o"

    for (let i = 0; i <= sample.length; i += 1) {
      for (const cmd of activeCommands(sample, i)) expect(names).toContain(cmd)
    }
  })

  test("an out-of-range offset is clamped rather than crashing", () => {
    expect(activeCommands("## Launch", 999)).toEqual(["h2"])
    expect(activeCommands("## Launch", -5)).toEqual(["h2"])
    expect(activeCommands(null, 0)).toEqual([])
    expect(activeCommands("", 0)).toEqual([])
  })
})
