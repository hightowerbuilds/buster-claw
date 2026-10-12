import {afterEach, expect, test} from "bun:test"
import {recoverRetiredRoute, recoverRetiredTabs} from "./retired_tabs.js"
import {browserAppTab, loadTabs, tabDestination} from "./tabs.js"
import {browserSurfaces, planTabLayout} from "./tab_layout.js"

const originalStorage = globalThis.localStorage
afterEach(() => { globalThis.localStorage = originalStorage })

test("old standalone tabs and settings destinations recover without duplicates", () => {
  const tabs = recoverRetiredTabs([
    {path: "/voice?tab=reading", label: "Vox2B"},
    {path: "/settings", href: "/appearance", label: "Settings"},
    {path: "/terminal?session=active", label: "Build"}
  ])
  expect(tabs).toEqual([
    {path: "/settings", href: "/settings?tab=speech", label: "Settings"},
    {path: "/terminal?session=active", label: "Build"}
  ])
  expect(recoverRetiredTabs(tabs)).toEqual(tabs)
  expect(recoverRetiredTabs([{path: "/settings", href: "/voice", label: "Settings"}])[0].href)
    .toBe("/settings?tab=speech")
})

test("recovering a split preserves the neighbor's exact browser path and metadata", () => {
  const browser = {path: "/browse?t=existing&surface=main&url=https%3A%2F%2Fexample.com%2Fx", label: "Research", url: "https://example.com/x"}
  const old = `/split?left=%2Fvoice&right=${encodeURIComponent(browser.path)}`
  const [tab] = recoverRetiredTabs([{path: old, label: "Vox2B | Research", panes: [{path: "/voice", label: "Vox2B"}, browser]}])
  expect(tab.panes[1]).toEqual(browser)
  expect(tab.panes[0]).toMatchObject({path: "/settings?tab=speech", label: "Speech"})
  expect(tab.label).toBe("Speech | Research")
  expect(browserSurfaces(tab.path)).toEqual(["main"])
  const separated = planTabLayout("separate", {}, [tab], tab.path, {labels: {}, joinable: ["/settings", "/browse"]})
  expect(separated.tabs).toContainEqual(browser)
  expect(separated.tabs[0].path).toBe("/settings?tab=speech")
  expect(tabDestination({path: old})).toBe(tab.path)
})

test("legacy implicit browser surface IDs stay on the same side", () => {
  const old = "/split?left=%2Fbrowse%3Ft%3Done&right=%2Fvoice"
  const recovered = recoverRetiredRoute(old)
  expect(browserSurfaces(recovered)).toEqual(["left"])
  expect(new URL(recovered, "http://app.local").searchParams.get("left")).toBe("/browse?t=one")
  expect(recoverRetiredRoute(recovered)).toBe(recovered)
})

test("loading saved tabs persists recovery without touching speech preferences", () => {
  const old = "/split?left=%2Fvoice&right=%2Fbrowse"
  const data = new Map([
    ["bc:tabs", JSON.stringify([{path: old, label: "Vox2B | Browse"}])],
    ["bc:browser-app-tab:right", old],
    ["bc:voice-out", "on"], ["bc:voice-name", "Samantha"], ["bc:voice-rate", "220"]
  ])
  globalThis.localStorage = {getItem: key => data.get(key) ?? null, setItem: (key, value) => data.set(key, value)}
  const tabs = loadTabs()
  expect(JSON.parse(data.get("bc:tabs"))).toEqual(tabs)
  expect(browserAppTab("right")).toBe(tabs[0].path)
  expect(data.get("bc:voice-out")).toBe("on")
  expect(data.get("bc:voice-name")).toBe("Samantha")
  expect(data.get("bc:voice-rate")).toBe("220")
})
