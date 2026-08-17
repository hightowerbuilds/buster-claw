import {expect, test, describe} from "bun:test"
import {
  MIN_POINT_DISTANCE,
  extend,
  pathData,
  round1,
  shouldKeep,
  toPoint,
} from "./sketch.js"

describe("toPoint", () => {
  const rect = {left: 100, top: 50}

  test("is relative to the surface, not the window", () => {
    expect(toPoint({clientX: 150, clientY: 80}, rect)).toEqual([50, 30])
  })

  test("rounds to one decimal, matching what the server stores" , () => {
    // Element rounds on the way in. Without the same rounding here the client
    // draws at one precision and the server hands back another, and the line
    // visibly shifts the moment it commits.
    expect(toPoint({clientX: 150.16, clientY: 80.44}, rect)).toEqual([50.2, 30.4])
  })

  test("a point above or left of the surface is negative, not clamped", () => {
    // Clamping would silently bend a stroke that started off-surface into the
    // edge. The document validates bounds; this is only arithmetic.
    expect(toPoint({clientX: 90, clientY: 40}, rect)).toEqual([-10, -10])
  })
})

describe("thinning", () => {
  test("the first point of a stroke is always kept" , () => {
    expect(shouldKeep([], [0, 0])).toBe(true)
    expect(shouldKeep(null, [0, 0])).toBe(true)
  })

  test("a point too close to the last one is dropped", () => {
    // A pointermove can fire per pixel. Keeping all of them makes a `d`
    // attribute of tens of kilobytes that crosses the wire, lands in a JSON
    // file, and is diffed on every change.
    expect(shouldKeep([[0, 0]], [1, 0])).toBe(false)
    expect(shouldKeep([[0, 0]], [MIN_POINT_DISTANCE, 0])).toBe(true)
  })

  test("distance is measured diagonally, not per axis", () => {
    // [1, 1] is 1.41 away — under the threshold — even though neither axis is.
    expect(shouldKeep([[0, 0]], [1, 1])).toBe(false)
    expect(shouldKeep([[0, 0]], [1.5, 1.5])).toBe(true)
  })

  test("extend returns the SAME array when it drops a point", () => {
    // How the hook cheaply tells whether anything changed, so it can skip
    // rewriting the path attribute on a move that added nothing.
    const points = [[0, 0]]

    expect(extend(points, [0.5, 0])).toBe(points)
    expect(extend(points, [10, 10])).not.toBe(points)
    expect(extend(points, [10, 10])).toEqual([[0, 0], [10, 10]])
  })

  test("extend never mutates what it was given", () => {
    const points = [[0, 0]]
    extend(points, [10, 10])

    expect(points).toEqual([[0, 0]])
  })
})

describe("pathData", () => {
  test("a stroke is a moveto and a run of linetos", () => {
    expect(pathData([[0, 0], [10, 5], [20, 15]])).toBe("M 0 0 L 10 5 L 20 15")
  })

  test("a tap with no movement is a dot, not nothing", () => {
    // A zero-length path does not render even with a round linecap, so a tap
    // would silently do nothing — which reads as the pad being broken.
    expect(pathData([[7, 3]])).toBe("M 7 3 L 7 3")
  })

  test("no points is an empty string, not a malformed path", () => {
    expect(pathData([])).toBe("")
    expect(pathData(null)).toBe("")
  })

  // These exact cases are asserted against the Elixir renderer too
  // (`BusterClawWeb.Studio.SketchSvgTest`). The hook draws a stroke while it is
  // being made and the server draws it the instant it commits; a disagreement
  // is not a rendering bug, it is a visible jump at the end of every stroke.
  test("agrees with the server renderer on the shared cases", () => {
    expect(pathData([[1.5, 2.5]])).toBe("M 1.5 2.5 L 1.5 2.5")
    expect(pathData([[0, 0], [1.1, 2.2]])).toBe("M 0 0 L 1.1 2.2")
    expect(pathData([[-5, 10], [0, 0], [5.5, -10.5]])).toBe("M -5 10 L 0 0 L 5.5 -10.5")
  })
})

describe("round1", () => {
  test("rounds half away from zero the way Elixir's Float.round does", () => {
    expect(round1(1.15)).toBe(1.2)
    expect(round1(2)).toBe(2)
    expect(round1(-3.14159)).toBe(-3.1)
  })
})
