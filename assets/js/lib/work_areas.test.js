import {describe, test, expect} from "bun:test"
import {areaIdForPath, areaPath, reconcileAreaTabs, areaTerminalKeys} from "./work_areas.js"
import {canonicalGroupKey, chromeChips, labelForPath, closeTabIn, tabDestination} from "./tabs.js"
import {clampFrame, moveFrame, workbenchGeometry} from "./workbench_overlap.js"
import {planTabLayout} from "./tab_layout.js"

const split = (a, b) => ({axis: "horizontal", ratio: .5, first: a, second: b})
const state = {version: 2, active_area_id: "area-2", areas: [
  {id: "area-1", number: 1, tree: split("chat", "terminal")},
  {id: "area-2", number: 2, tree: split("notes", "terminal-2")},
]}

describe("numbered work area tabs", () => {
  test("area identities exclude panel and ask actions and retain only the area", () => {
    for (const path of ["/?area=area-2", "/?panel=notes&area=area-2", "/?ask=page&area=area-2"]) {
      expect(areaIdForPath(path)).toBe("area-2")
      expect(canonicalGroupKey(path)).toBe("/?area=area-2")
      expect(labelForPath(path)).toBe("Work Area 2")
    }
    expect(areaPath("area-1")).toBe("/")
    expect(areaIdForPath("/?area=bad")).toBe("area-1")
    expect(areaIdForPath("//external/")).toBeNull()
    expect(areaIdForPath("/settings?area=area-2")).toBeNull()
    expect(tabDestination({path: "/?area=area-2", href: "/?area=area-3"})).toBe("/?area=area-2")
  })
  test("reconciliation repairs missing tabs, removes stale ones and retains names and order", () => {
    const tabs = [{path: "/settings", label: "Settings"}, {path: "/", label: "Writing"}, {path: "/?area=area-9", label: "Gone"}]
    const repaired = reconcileAreaTabs(tabs, state)
    expect(repaired.map(t => t.path)).toEqual(["/settings", "/", "/?area=area-2"])
    expect(repaired[1].label).toBe("Writing")
    expect(repaired[2].label).toBe("Work Area 2")
    expect(reconcileAreaTabs(repaired, state)).toEqual(repaired)
    expect(areaTerminalKeys(state, "area-2")).toEqual(["terminal-2"])
  })
  test("native chips retain secondary work areas and pin only the first", () => {
    const tabs = reconcileAreaTabs([], state)
    const chips = chromeChips(tabs, "/browse")
    expect(chips.map(t => t.label)).toEqual(["Work Area", "Work Area 2"])
    expect(chips.map(t => t.closable)).toEqual([false, true])
    expect(closeTabIn(tabs, "/").closed).toBe(false)
    expect(closeTabIn(tabs, "/?area=area-2").closed).toBe(true)
  })
  test("joined areas are not duplicated, and two work areas cannot be joined", () => {
    const joined = {path: "/split?left=%2F%3Farea%3Darea-2&right=%2Fbrowse", label: "Work Area 2 | Browser"}
    expect(reconcileAreaTabs([joined], state).map(t => t.path)).toEqual([joined.path, "/"])
    expect(() => planTabLayout("join", {tab: "/?area=area-2"}, reconcileAreaTabs([], state), "/", {
      labels: {"/": "Work Area"}, joinable: ["/"],
    })).toThrow("Two Work Areas")
  })
})

describe("overlap geometry", () => {
  const area = {mode: "overlap", tree: split("chat", "notes"), frames: {
    chat: {x: .1, y: .1, width: .6, height: .6}, notes: {x: .2, y: .2, width: .6, height: .6},
  }}
  test("free frames overlap and keep their own dimensions without grid dividers", () => {
    const result = workbenchGeometry(area, 1000, 800)
    expect(result.dividers).toEqual([])
    expect(result.panes.chat).toEqual({x: 100, y: 80, width: 600, height: 480})
    expect(result.panes.notes).toEqual({x: 200, y: 160, width: 600, height: 480})
    expect(workbenchGeometry({...area, mode: "grid"}, 1000, 800).dividers).toHaveLength(1)
    expect(workbenchGeometry({...area, zoom: "notes"}, 1000, 800).panes.notes.width).toBe(1000)
  })
  test("movement clamps to the canvas without changing size or mutating another frame", () => {
    const frame = moveFrame(area.frames.chat, 2000, -1000, 1000, 800)
    expect(frame).toEqual({x: .4, y: 0, width: .6, height: .6})
    expect(area.frames.chat.x).toBe(.1)
    expect(moveFrame(frame, 20, 20, 0, 0)).toEqual(frame)
    expect(clampFrame({...frame, x: Infinity})).toBeNull()
    expect(clampFrame({...frame, y: NaN})).toBeNull()
  })
})
