import {expect, test} from "bun:test"
import {installBrowserNav} from "./browser_nav.js"

test("Graph opens its own surface's pane without navigating the agent's page", () => {
  const previousDocument = globalThis.document
  const previousStorage = globalThis.localStorage
  const handlers = new Map(), writes = [], calls = []
  globalThis.document = {getElementById: id => ({addEventListener: (_event, callback) => handlers.set(id, callback)})}
  globalThis.localStorage = {setItem: (key, value) => writes.push([key, JSON.parse(value)])}
  try {
    let tab = "original"
    installBrowserNav((...args) => calls.push(args), () => tab, "http://localhost", "/browser/home", "left")
    handlers.get("activity")()
    expect(calls).toEqual([])
    expect(writes[0][0]).toBe("bc.browser.activity")
    expect(writes[0][1].sid).toBe("left")

    tab = "next"
    handlers.get("reload")()
    expect(calls).toEqual([["browser_reload", {tabId: "next"}]])
  } finally {
    globalThis.document = previousDocument
    globalThis.localStorage = previousStorage
  }
})
