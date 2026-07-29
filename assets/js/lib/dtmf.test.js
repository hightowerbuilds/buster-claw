import {expect, test} from "bun:test"
import {DTMF, dtmfPair} from "./dtmf.js"

test("all twelve dialpad keys carry a tone pair", () => {
  for (const key of ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]) {
    const pair = dtmfPair(key)
    expect(pair).toHaveLength(2)
    expect(pair[0]).toBeLessThan(pair[1]) // low group first, by construction
  }
})

test("the grid is the Q.23 spec, not an approximation", () => {
  // Spot-check the corners and the famous ones — a wrong frequency here is a
  // wrong NUMBER dialed on any real DTMF decoder listening.
  expect(DTMF["1"]).toEqual([697, 1209])
  expect(DTMF["5"]).toEqual([770, 1336])
  expect(DTMF["9"]).toEqual([852, 1477])
  expect(DTMF["0"]).toEqual([941, 1336])
  expect(DTMF["*"]).toEqual([941, 1209])
  expect(DTMF["#"]).toEqual([941, 1477])
})

test("non-keys are null, not a crash and not a tone", () => {
  expect(dtmfPair("A")).toBeNull()
  expect(dtmfPair("")).toBeNull()
  expect(dtmfPair(undefined)).toBeNull()
})

test("every pair is unique — twelve keys, twelve distinguishable sounds", () => {
  const pairs = Object.values(DTMF).map((p) => p.join("/"))
  expect(new Set(pairs).size).toBe(12)
})
