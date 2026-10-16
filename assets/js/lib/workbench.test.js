import {describe, test, expect} from "bun:test"
import {panelGeometry, layoutDots, resizeTree, readLayout, saveLayout} from "./workbench.js"

const split = {axis: "horizontal", ratio: 0.5, first: "chat", second: {axis: "vertical", ratio: 0.4, first: "terminal", second: "clock"}}

describe("work-area geometry", () => {
  test("nested splits cover the canvas with non-overlapping panes and eight-pixel dividers", () => {
    const {panes, dividers} = panelGeometry(split, 1000, 600)
    expect(panes.chat).toEqual({x: 0, y: 0, width: 496, height: 600})
    expect(panes.terminal.x).toBe(504)
    expect(panes.clock.y).toBeCloseTo(244.8)
    expect(panes.clock.height + panes.clock.y).toBe(600)
    expect(dividers).toHaveLength(2)
    expect(dividers[1].path).toEqual(["second"])
  })
  test("maximize uses the whole canvas without changing the stored tree", () => {
    const {panes, dividers} = panelGeometry(split, 1000, 600, "clock")
    expect(Object.keys(panes)).toEqual(["clock"])
    expect(panes.clock.width).toBe(1000)
    expect(dividers).toEqual([])
    expect(split.second.ratio).toBe(0.4)
  })
  test("dragging a nested divider changes only that split", () => {
    const next = resizeTree(split, ["second"], 0.7)
    expect(next.ratio).toBe(0.5)
    expect(next.second.ratio).toBe(0.7)
    expect(split.second.ratio).toBe(0.4)
    expect(resizeTree(split, [], 0).ratio).toBe(0.15)
  })
  test("collapsed containers never produce negative pane sizes", () => {
    for (const box of Object.values(panelGeometry(split, 0, 0).panes)) {
      expect(box.width).toBeGreaterThanOrEqual(0)
      expect(box.height).toBeGreaterThanOrEqual(0)
    }
  })
  test("unavailable or malformed storage cannot prevent the work area from opening", () => {
    expect(readLayout({getItem: () => "broken"})).toBeNull()
    expect(readLayout(undefined)).toBeNull()
    expect(() => saveLayout(undefined, {tree: "chat"})).not.toThrow()
  })
  test("picker dots mark each panel's center, including a pane beside two stacked panes", () => {
    const dots = layoutDots(split)
    expect(dots).toHaveLength(3)
    expect(dots[0].x).toBeLessThan(dots[1].x)
    expect(dots[0].y).toBe(50)
    expect(dots[1].x).toBe(dots[2].x)
    expect(dots[1].y).toBeLessThan(dots[2].y)
    for (const dot of dots) {
      expect(dot.x).toBeGreaterThan(0)
      expect(dot.x).toBeLessThan(100)
      expect(dot.y).toBeGreaterThan(0)
      expect(dot.y).toBeLessThan(100)
    }
  })
})
