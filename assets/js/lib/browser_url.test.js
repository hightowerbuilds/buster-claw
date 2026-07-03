// bun test — pure-logic tests for the shared browser URL heuristics.
// Run: bun test assets/js/lib/ (from the repo root)
import {describe, expect, test} from "bun:test"
import {resolve, display, deriveLabel, faviconFor, DEFAULT_SEARCH_URL} from "./browser_url.js"

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
    expect(resolve("rust-lang.org", ORIGIN)).toBe("https://rust-lang.org")
  })

  test("routes text with spaces to the search engine", () => {
    expect(resolve("tauri webview zoom", ORIGIN)).toBe(
      DEFAULT_SEARCH_URL + encodeURIComponent("tauri webview zoom")
    )
  })

  test("routes dotless single words to the search engine", () => {
    expect(resolve("elixir", ORIGIN)).toBe(DEFAULT_SEARCH_URL + "elixir")
    expect(resolve("hello?", ORIGIN)).toBe(DEFAULT_SEARCH_URL + encodeURIComponent("hello?"))
  })

  test("localhost (with or without port) is a URL, not a search", () => {
    expect(resolve("localhost", ORIGIN)).toBe("https://localhost")
    expect(resolve("localhost:4000/x", ORIGIN)).toBe("https://localhost:4000/x")
  })

  test("honors a custom search engine", () => {
    expect(resolve("cats", ORIGIN, {searchUrl: "https://kagi.com/search?q="})).toBe(
      "https://kagi.com/search?q=cats"
    )
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

  test("http(s) hosts get the LOCAL favicon endpoint (never a third party)", () => {
    expect(faviconFor("https://example.com/x", ORIGIN)).toBe(
      `${ORIGIN}/browser/favicon?host=example.com`
    )
  })
})
