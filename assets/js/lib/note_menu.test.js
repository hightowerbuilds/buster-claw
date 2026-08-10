import {expect, test, describe} from "bun:test"
import {menuPosition} from "./note_menu.js"

describe("menuPosition", () => {
  const viewport = {width: 1000, height: 800}
  const size = {width: 200, height: 120}

  test("lands at the cursor when there is room", () => {
    expect(menuPosition({point: {x: 300, y: 200}, size, viewport})).toEqual({x: 300, y: 200})
  })

  test("flips to the left of the cursor rather than off the right edge", () => {
    const {x} = menuPosition({point: {x: 950, y: 200}, size, viewport})
    expect(x).toBe(750)
    expect(x + size.width).toBeLessThanOrEqual(viewport.width)
  })

  test("flips above the cursor rather than off the bottom edge", () => {
    const {y} = menuPosition({point: {x: 300, y: 780}, size, viewport})
    expect(y).toBe(660)
    expect(y + size.height).toBeLessThanOrEqual(viewport.height)
  })

  test("a corner click flips both ways at once, and still keeps its margin", () => {
    // Flipping alone would leave it 3px from each far edge, so the clamp is
    // doing the second half of the job here rather than being redundant.
    expect(menuPosition({point: {x: 995, y: 795}, size, viewport})).toEqual({x: 792, y: 672})
  })

  test("a box bigger than the window starts at the margin, not above it", () => {
    // Flipping would put this one at a negative coordinate, which is the
    // failure the clamp exists for: the first item must stay reachable.
    const tall = {width: 200, height: 900}
    expect(menuPosition({point: {x: 300, y: 700}, size: tall, viewport}).y).toBe(8)
  })

  test("the margin is honoured on the near edges too", () => {
    expect(menuPosition({point: {x: 0, y: 0}, size, viewport})).toEqual({x: 8, y: 8})
  })

  test("missing numbers position the menu instead of returning NaN", () => {
    // A hook that measured a still-hidden element gets zeroes; a menu parked at
    // the margin is recoverable, `left: NaNpx` is not.
    expect(menuPosition({})).toEqual({x: 8, y: 8})
  })
})
