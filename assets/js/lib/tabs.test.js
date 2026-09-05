// bun test — pure-logic tests for the tab-strip grouping helpers.
// Run: bun test assets/js/lib/ (from the repo root)
import {describe, expect, test} from "bun:test"
import {canonicalGroupKey, labelForPath} from "./tabs.js"

describe("canonicalGroupKey", () => {
  test("Settings sub-routes collapse onto /settings", () => {
    for (const p of [
      "/settings",
      "/appearance",
      "/notify-settings",
      "/integrations",
      "/security",
      "/cmd-list"
    ]) {
      expect(canonicalGroupKey(p)).toBe("/settings")
    }
  })

  test("the removed /gws and /get-started routes no longer group", () => {
    expect(canonicalGroupKey("/gws")).toBeNull()
    expect(canonicalGroupKey("/get-started")).toBeNull()
  })

  // /voice left the Settings rail on 09-05 when the surface became the Home
  // "Vox2B" sub-tab. Pinned as its own case rather than just deleted from the
  // list above: an ungrouped route needs a label in Layouts' @tab_labels, and
  // silently re-adding /voice to the group would take that label out of use
  // without anything saying so.
  test("/voice no longer collapses into Settings", () => {
    expect(canonicalGroupKey("/voice")).toBeNull()
    expect(labelForPath("/voice", {"/voice": "Vox2B"})).toBe("Vox2B")
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
