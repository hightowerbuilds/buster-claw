import {expect, test} from "bun:test"
import {TabLayout} from "./tab_layout.js"

test("agent join acknowledges before moving live browser surfaces, never closing them", async () => {
  const previousWindow = globalThis.window, previousStorage = globalThis.localStorage
  const operations = []
  globalThis.localStorage = {getItem: () => null}
  globalThis.window = {__TAURI__: {core: {invoke: async (command, args) => { operations.push([command, args]) }}},
    location: {set href(path) { operations.push(["navigate", path]) }}}
  try {
    let tabs = [{path: "/", label: "Home"}, {path: "/browse", label: "Browser"}]
    let acknowledge, navigation
    const hook = {...TabLayout,
      labels: {"/": "Home", "/browse": "Browser"}, el: {dataset: {joinable: '["/","/browse"]'}},
      currentKey: () => "/", load: () => tabs, save: next => { tabs = next },
      pushEvent: (_event, payload, callback) => { operations.push(["result", payload]); acknowledge = callback },
      navigateLayout(path) { navigation = TabLayout.navigateLayout.call(this, path); return navigation }
    }
    await hook.onTabRequest({ref: "one", action: "join", args: {tab: "browser"}})
    expect(operations.map(op => op[0])).toEqual(["result"])
    expect(tabs.length).toBe(1)
    acknowledge({accepted: true})
    await navigation
    expect(operations.at(-1)[0]).toBe("navigate")
    expect(operations.some(op => op[0] === "browser_close")).toBe(false)
    expect(operations.at(-1)[1]).toContain("surface%3Dmain")
  } finally {
    globalThis.window = previousWindow
    globalThis.localStorage = previousStorage
  }
})

test("rejected and expired requests leave the tab layout unchanged", async () => {
  const previousStorage = globalThis.localStorage
  globalThis.localStorage = {getItem: () => null}
  try {
    const before = [{path: "/", label: "Home"}, {path: "/browse", label: "Browser"}]
    let tabs = before, result
    const hook = {...TabLayout,
      labels: {"/": "Home", "/browse": "Browser"}, el: {dataset: {joinable: '["/","/browse"]'}},
      currentKey: () => "/", load: () => tabs, save: next => { tabs = next },
      pushEvent: (_event, payload, callback) => { result = payload.result; callback({accepted: false}) },
      navigateLayout() { throw new Error("must not navigate") }
    }
    await hook.onTabRequest({ref: "late", action: "join", args: {tab: "browser"}})
    expect(tabs).toEqual(before)
    await hook.onTabRequest({ref: "expired", action: "join", args: {tab: "browser"}, expires_at: Date.now() - 1000})
    expect(result.error).toContain("expired")
    expect(tabs).toEqual(before)
  } finally { globalThis.localStorage = previousStorage }
})

test("a failed storage write reports the error without navigating", async () => {
  const previousStorage = globalThis.localStorage
  globalThis.localStorage = {getItem: () => null}
  try {
    let result
    const hook = {...TabLayout,
      labels: {"/": "Home", "/browse": "Browser"}, el: {dataset: {joinable: '["/","/browse"]'}},
      currentKey: () => "/", load: () => [{path: "/", label: "Home"}],
      save() { throw new Error("Storage full") },
      pushEvent: (_event, payload, callback) => { result = payload.result; callback({accepted: false}) },
      navigateLayout() { throw new Error("must not navigate") }
    }
    await hook.onTabRequest({ref: "full", action: "join", args: {tab: "browser"}})
    expect(result).toEqual({error: "Storage full"})
  } finally { globalThis.localStorage = previousStorage }
})

test("deleting a moved browser or legacy split closes only its own surfaces", async () => {
  const previousWindow = globalThis.window
  const closed = []
  globalThis.window = {__TAURI__: {core: {invoke: async (command, args) => { closed.push([command, args.surfaceId]) }}}}
  try {
    await TabLayout.tearDownSplitBrowsers("/browse?surface=tab123")
    expect(closed).toEqual([["browser_close", "tab123"]])
    await TabLayout.tearDownSplitBrowsers("/split?left=%2Fbrowse&right=%2Fbrowse")
    expect(closed).toEqual([["browser_close", "tab123"], ["browser_close", "left"], ["browser_close", "right"]])
  } finally { globalThis.window = previousWindow }
})
