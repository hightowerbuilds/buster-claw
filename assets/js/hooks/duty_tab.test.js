import {describe, expect, test} from "bun:test"
import {dutyTabs} from "./duty_tab.js"

describe("conditional duty tab", () => {
  test("appears once alongside existing tabs and keeps their state", () => {
    const home = {path: "/", label: "My chat"}
    const active = dutyTabs([home], true)
    expect(active).toEqual([home, {path: "/duty", label: "On duty"}])
    expect(dutyTabs(active, true)).toEqual(active)
    expect(active[0]).toBe(home)
  })

  test("removes a persisted duty tab when the shift has ended", () => {
    const tabs = [{path: "/duty", label: "Old duty"}, {path: "/workspace", label: "Workspace"}]
    expect(dutyTabs(tabs, false)).toEqual([tabs[1]])
    expect(tabs).toHaveLength(2)
  })

  test("preserves the duty tab's position while active", () => {
    expect(dutyTabs([{path: "/duty"}, {path: "/"}], true)[0]).toEqual({path: "/duty", label: "On duty"})
  })
})
