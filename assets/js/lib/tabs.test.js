// bun test — pure-logic tests for the tab-strip grouping helpers.
// Run: bun test assets/js/lib/ (from the repo root)
import {describe, expect, test} from "bun:test"
import {canonicalGroupKey, chromeChips, closeTabIn, labelForPath, tabDestination} from "./tabs.js"

// 09-13-26: the browser chrome's row of app tabs could switch tabs but not close
// them, and on /browse that row is the only tab strip you can reach — the DOM
// strip is under the native webview. Both close buttons now share this rule.
describe("closeTabIn", () => {
  const tabs = [{path: "/"}, {path: "/browse?t=a"}, {path: "/terminal?session=x"}]

  test("the tab that slides into the closed slot takes the screen", () => {
    const {tabs: rest, closed, next} = closeTabIn(tabs, "/browse?t=a")
    expect(closed).toBe(true)
    expect(rest.map((t) => t.path)).toEqual(["/", "/terminal?session=x"])
    expect(next.path).toBe("/terminal?session=x")
  })

  test("closing the last tab falls back to the one before it", () => {
    expect(closeTabIn(tabs, "/terminal?session=x").next.path).toBe("/browse?t=a")
  })

  test("closing the only tab leaves nowhere, which means Home", () => {
    const {tabs: rest, next} = closeTabIn([{path: "/browse?t=a"}], "/browse?t=a")
    expect(rest).toEqual([])
    expect(next).toBeNull()
  })

  test("the duty tab and unknown paths stay, and the list comes back untouched", () => {
    const withDuty = tabs.concat([{path: "/duty"}])
    expect(closeTabIn(withDuty, "/duty")).toEqual({tabs: withDuty, closed: false, next: null})
    expect(closeTabIn(tabs, "/nope").closed).toBe(false)
  })

  test("does not mutate the list it was given", () => {
    const before = JSON.parse(JSON.stringify(tabs))
    closeTabIn(tabs, "/browse?t=a")
    expect(tabs).toEqual(before)
  })
})

describe("chromeChips", () => {
  const split = "/split?left=%2Fbrowse&right=%2Fterminal"
  const saved = [
    {path: "/", label: "Home"},
    {path: "/browse?t=a", label: "Browser"},
    {path: "/browse?t=b", label: "Browser 2"},
    {path: split, label: "Browser | Terminal"},
    {path: "/duty", label: "On duty"},
  ]
  const byPath = (chips) => Object.fromEntries(chips.map((c) => [c.path, c]))

  test("Home comes first, exactly once, and is never closable", () => {
    const chips = chromeChips(saved, "/browse?t=a")
    expect(chips[0]).toMatchObject({path: "/", current: false, closable: false})
    expect(chips.filter((c) => c.path === "/").length).toBe(1)
  })

  test("the tab you are on has a close button — the defect", () => {
    const chips = byPath(chromeChips(saved, "/browse?t=a"))
    expect(chips["/browse?t=a"]).toMatchObject({current: true, closable: true})
    expect(chips["/browse?t=b"]).toMatchObject({current: false, closable: true})
  })

  test("with nothing recorded, every browser tab counts as here, as before", () => {
    const chips = byPath(chromeChips(saved, null))
    expect(chips["/browse?t=a"].current).toBe(true)
    expect(chips["/browse?t=b"].current).toBe(true)
  })

  test("a split you are inside is not closed from one pane; one in the background is", () => {
    expect(byPath(chromeChips(saved, split))[split]).toMatchObject({current: true, closable: false})
    expect(byPath(chromeChips(saved, "/browse?t=a"))[split]).toMatchObject({current: false, closable: true})
  })

  test("the duty tab is shown but never closable", () => {
    expect(byPath(chromeChips(saved, "/browse?t=a"))["/duty"].closable).toBe(false)
  })

  test("junk in storage is dropped rather than rendered", () => {
    expect(chromeChips([null, {path: 7}, {path: "relative"}], null).map((c) => c.path)).toEqual(["/"])
  })
})

describe("remembered Settings destination", () => {
  test("removed and moved subpages fall back to Appearance", () => {
    for (const href of ["/cmd-list", "/cmd-list?tab=commands", "/voice", "/gws", "/get-started"]) {
      expect(tabDestination({path: "/settings", href})).toBe("/appearance")
    }
  })

  test("current subpages retain their query and fragment", () => {
    expect(tabDestination({path: "/settings", href: "/security?filter=recent#events"}))
      .toBe("/security?filter=recent#events")
    expect(tabDestination({path: "/settings", href: "/appearance"})).toBe("/appearance")
  })

  test("ordinary tabs and Settings with no remembered page keep their destination", () => {
    expect(tabDestination({path: "/terminal?session=one"})).toBe("/terminal?session=one")
    expect(tabDestination({path: "/settings"})).toBe("/settings")
  })
})

describe("canonicalGroupKey", () => {
  test("Settings sub-routes collapse onto /settings", () => {
    for (const p of [
      "/settings",
      "/appearance",
      "/notify-settings",
      "/integrations",
      "/security"
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
    const labels = {"/appearance": "Settings", "/notify-settings": "Settings"}
    expect(labelForPath("/appearance", labels)).toBe("Settings")
    expect(labelForPath("/notify-settings", labels)).toBe("Settings")
  })
})
