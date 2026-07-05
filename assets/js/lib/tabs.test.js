// bun test — pure-logic tests for the tab-strip grouping helpers.
// Run: bun test assets/js/lib/ (from the repo root)
import {describe, expect, test} from "bun:test"
import {canonicalGroupKey, labelForPath} from "./tabs.js"

describe("canonicalGroupKey", () => {
  test("Settings sub-routes collapse onto /settings", () => {
    for (const p of [
      "/settings",
      "/appearance",
      "/voice",
      "/integrations",
      "/security",
      "/get-started",
      "/cmd-list"
    ]) {
      expect(canonicalGroupKey(p)).toBe("/settings")
    }
  })

  test("the removed /gws route no longer groups", () => {
    expect(canonicalGroupKey("/gws")).toBeNull()
  })

  test("ungrouped routes return null", () => {
    for (const p of ["/", "/terminal", "/browse", "/calendar", "/workspace"]) {
      expect(canonicalGroupKey(p)).toBeNull()
    }
  })
})

describe("labelForPath", () => {
  test("labels a Settings sub-route from the provided map", () => {
    const labels = {"/appearance": "Settings", "/cmd-list": "Settings"}
    expect(labelForPath("/appearance", labels)).toBe("Settings")
    expect(labelForPath("/cmd-list", labels)).toBe("Settings")
  })
})
