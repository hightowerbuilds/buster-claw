import {describe, expect, test} from "bun:test"
import {browserSurfaces, planTabLayout, splitPanes, tabSnapshot} from "./tab_layout.js"
const options = {labels: {"/": "Home", "/browse": "Browser", "/terminal": "Terminal", "/calendar": "Calendar", "/settings": "Settings"},
  joinable: ["/", "/browse", "/terminal", "/calendar", "/settings", "/appearance"], browserOwner: "/browse?t=live"}
const home = {path: "/", label: "Home"}
const browser = {path: "/browse?t=live", label: "Research", url: "https://example.com/paper"}
const join = (tabs = [home, browser], args = {tab: "browser"}, current = "/") => planTabLayout("join", args, tabs, current, options)

describe("chat tab layouts", () => {
  test("joins the already-open browser, retaining its surface, URL, identity and label", () => {
    const tabs = [home, browser, {path: "/calendar", label: "Calendar"}]
    const before = JSON.stringify(tabs)
    const plan = join(tabs)
    expect(tabs.length).toBe(3)
    expect(JSON.stringify(tabs)).toBe(before)
    expect(plan.tabs.length).toBe(2)
    const panes = splitPanes(plan.tabs[1])
    expect(panes[0].path).toBe("/")
    expect(panes[1].label).toBe("Research")
    expect(panes[1].path).toContain("t=live")
    expect(panes[1].path).toContain("surface=main")
    expect(new URL(panes[1].path, "http://app").searchParams.get("url")).toBe(browser.url)
    expect(browserSurfaces(plan.path)).toEqual(["main"])
  })

  test("separates into both tabs and focuses chat without destroying browser state", () => {
    const joined = join()
    const separate = planTabLayout("separate", {}, joined.tabs, joined.path, options)
    expect(separate.tabs.length).toBe(2)
    expect(separate.path).toBe("/")
    expect(separate.tabs[1].label).toBe("Research")
    expect(browserSurfaces(separate.tabs[1].path)).toEqual(["main"])
    const rejoined = join(separate.tabs)
    expect(browserSurfaces(rejoined.path)).toEqual(["main"])
    expect(rejoined.tabs.length).toBe(1)
  })

  test("joining the same pair again is a no-op", () => {
    const plan = join()
    expect(join(plan.tabs, {tab: "browser"}, plan.path)).toMatchObject({path: plan.path, changed: false})
    expect(join(plan.tabs, {tab: browser.path, with: "/"}, plan.path).changed).toBe(false)
  })

  test("creates a supported view only when no matching tab is open", () => {
    const plan = join([home], {tab: "browser"})
    expect(plan.tabs.length).toBe(1)
    expect(splitPanes(plan.tabs[0])[1].path).toContain("/browse?")
  })

  test("ambiguous browser labels require an exact path", () => {
    const tabs = [home, browser, {path: "/browse?t=other", label: "Other"}]
    expect(() => join(tabs)).toThrow("Several tabs match")
    expect(join(tabs, {tab: browser.path}).tabs.length).toBe(2)
  })

  test("rejects unsupported routes, nested splits, and untrusted destinations", () => {
    for (const tab of ["/setup", "https://example.com", "//example.com", "/\\evil", "/split?left=/&right=/browse", "/duty", "/browse?url=https://example.com"]) {
      expect(() => join([home], {tab})).toThrow()
    }
    expect(() => join([home], {tab: "chat"})).toThrow("different tabs")
    const settings = join([home, {path: "/settings", href: "//evil", label: "Settings"}], {tab: "settings"})
    expect(splitPanes(settings.tabs[0])[1].path).toBe("/appearance")
  })

  test("keeps terminal session parameters and custom labels", () => {
    const terminal = {path: "/terminal?session=agent123&label=Shell", label: "My session", role_key: "coder"}
    const plan = join([home, terminal], {tab: "terminal"})
    const separate = planTabLayout("separate", {}, plan.tabs, plan.path, options)
    expect(separate.tabs[1]).toMatchObject(terminal)
  })

  test("swapping legacy splits keeps each browser's native surface", () => {
    const path = "/split?left=%2Fbrowse&right=%2Fbrowse"
    const plan = planTabLayout("swap", {tab: path}, [{path, label: "Browsers"}], path, options)
    expect(browserSurfaces(plan.path)).toEqual(["right", "left"])
    const separate = planTabLayout("separate", {}, plan.tabs, plan.path, options)
    expect(separate.tabs.map(tab => browserSurfaces(tab.path)[0])).toEqual(["right", "left"])
  })

  test("reports joined children in the list and never separates a solo tab", () => {
    const plan = join()
    expect(tabSnapshot(plan.tabs, plan.path).tabs[0].panes.length).toBe(2)
    expect(() => planTabLayout("separate", {}, [home], "/", options)).toThrow("not joined")
  })
})
