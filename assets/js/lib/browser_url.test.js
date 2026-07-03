// bun test — pure-logic tests for the shared browser URL heuristics.
// Run: bun test assets/js/lib/ (from the repo root)
import {describe, expect, test} from "bun:test"
import {resolve, display, deriveLabel, faviconFor} from "./browser_url.js"

const ORIGIN = "http://127.0.0.1:4000"

describe("resolve", () => {
  test("empty input is null (caller decides the fallback)", () => {
    expect(resolve("", ORIGIN)).toBeNull()
    expect(resolve("   ", ORIGIN)).toBeNull()
    expect(resolve(null, ORIGIN)).toBeNull()
  })

  test("keeps an explicit scheme", () => {
    expect(resolve("https://example.com/a", ORIGIN)).toBe("https://example.com/a")
    expect(resolve("http://example.com", ORIGIN)).toBe("http://example.com")
  })

  test("routes absolute workspace paths to /ws/file", () => {
    expect(resolve("/notes/today.md", ORIGIN)).toBe(
      `${ORIGIN}/ws/file?path=${encodeURIComponent("/notes/today.md")}`
    )
  })

  test("prefixes bare domains with https", () => {
    expect(resolve("example.com", ORIGIN)).toBe("https://example.com")
    expect(resolve("  example.com/p  ", ORIGIN)).toBe("https://example.com/p")
  })
})

describe("display", () => {
  test("homepage displays blank", () => {
    expect(display(`${ORIGIN}/browser/home`, ORIGIN)).toBe("")
  })

  test("workspace file displays as its path", () => {
    const u = `${ORIGIN}/ws/file?path=${encodeURIComponent("/notes/today.md")}`
    expect(display(u, ORIGIN)).toBe("/notes/today.md")
  })

  test("workspace browse displays its query", () => {
    const u = `${ORIGIN}/browser/workspace?q=${encodeURIComponent("/notes")}`
    expect(display(u, ORIGIN)).toBe("/notes")
  })

  test("external URLs display verbatim", () => {
    expect(display("https://example.com/a?b=c", ORIGIN)).toBe("https://example.com/a?b=c")
  })
})

describe("deriveLabel", () => {
  test("home and empty are New tab", () => {
    expect(deriveLabel("", ORIGIN)).toBe("New tab")
    expect(deriveLabel(`${ORIGIN}/browser/home`, ORIGIN)).toBe("New tab")
  })

  test("workspace file labels by basename", () => {
    const u = `${ORIGIN}/ws/file?path=${encodeURIComponent("/notes/today.md")}`
    expect(deriveLabel(u, ORIGIN)).toBe("today.md")
  })

  test("external labels by hostname sans www", () => {
    expect(deriveLabel("https://www.example.com/deep/path", ORIGIN)).toBe("example.com")
  })
})

describe("faviconFor", () => {
  test("no favicon for our own origin or non-http schemes", () => {
    expect(faviconFor(`${ORIGIN}/browser/home`, ORIGIN)).toBeNull()
    expect(faviconFor("about:blank", ORIGIN)).toBeNull()
  })

  test("http(s) hosts get a favicon URL", () => {
    expect(faviconFor("https://example.com/x", ORIGIN)).toContain("example.com")
  })
})
