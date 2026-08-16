import {expect, test, describe} from "bun:test"
import {
  analyse,
  band,
  createHold,
  meterFraction,
  toDb,
  FLOOR_DB,
} from "./meter.js"

const block = (values) => Float32Array.from(values)

describe("toDb", () => {
  test("full scale is 0 dBFS", () => {
    expect(toDb(1.0)).toBe(0)
  })

  test("half amplitude is about -6 dBFS", () => {
    expect(toDb(0.5)).toBeCloseTo(-6.02, 1)
  })

  test("silence floors instead of returning -Infinity", () => {
    expect(toDb(0)).toBe(FLOOR_DB)
    expect(Number.isFinite(toDb(0))).toBe(true)
  })

  test("anything below the floor clamps to it", () => {
    expect(toDb(0.0000001)).toBe(FLOOR_DB)
  })
})

describe("meterFraction", () => {
  test("the floor is empty and full scale is full", () => {
    expect(meterFraction(FLOOR_DB)).toBe(0)
    expect(meterFraction(0)).toBe(1)
  })

  test("above full scale does not overflow the bar", () => {
    expect(meterFraction(6)).toBe(1)
  })

  test("a non-finite level renders as empty rather than NaN", () => {
    expect(meterFraction(-Infinity)).toBe(0)
    expect(meterFraction(NaN)).toBe(0)
  })
})

describe("analyse", () => {
  test("peak is the largest magnitude, sign-independent", () => {
    expect(analyse(block([0.1, -0.8, 0.3])).peak).toBeCloseTo(0.8, 5)
  })

  test("rms of a constant block is that constant", () => {
    expect(analyse(block([0.5, 0.5, 0.5, 0.5])).rms).toBeCloseTo(0.5, 5)
  })

  test("rms is not peak — one transient over a quiet take", () => {
    const {peak, rms} = analyse(block([0.9, 0.01, 0.01, 0.01]))
    expect(peak).toBeCloseTo(0.9, 5)
    expect(rms).toBeLessThan(0.5)
  })

  test("full scale reads as clipped, in either direction", () => {
    expect(analyse(block([0.2, 1.0])).clipped).toBe(true)
    expect(analyse(block([0.2, -1.0])).clipped).toBe(true)
  })

  test("just below full scale is not clipped", () => {
    expect(analyse(block([0.999])).clipped).toBe(false)
  })

  test("an empty block is silence, not NaN", () => {
    const {peak, rms, clipped} = analyse(block([]))
    expect(peak).toBe(0)
    expect(rms).toBe(0)
    expect(clipped).toBe(false)
  })
})

describe("band", () => {
  test("the target zone is its own band, and over is not the top of it", () => {
    expect(band(-30)).toBe("low")
    expect(band(-9)).toBe("good")
    expect(band(-3)).toBe("hot")
    expect(band(0)).toBe("over")
  })
})

describe("createHold", () => {
  test("holds the highest peak and never falls on its own", () => {
    const hold = createHold()
    hold.push(0.4)
    hold.push(0.9)
    hold.push(0.1)

    expect(hold.value.hold).toBeCloseTo(0.9, 5)
  })

  test("clip LATCHES — a 40 ms clip is still lit later", () => {
    const hold = createHold()
    hold.push(1.0)
    for (let i = 0; i < 100; i++) hold.push(0.01)

    expect(hold.value.clipped).toBe(true)
  })

  test("reset is the only way down", () => {
    const hold = createHold()
    hold.push(1.0)
    hold.reset()

    expect(hold.value).toEqual({hold: 0, clipped: false})
  })
})
