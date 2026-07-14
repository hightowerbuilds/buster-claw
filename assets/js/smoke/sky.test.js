import {describe, expect, test} from "bun:test"
import {skyAmounts, localDayFrac} from "./sky.js"

describe("skyAmounts", () => {
  test("clear sky: no precipitation, cloud from cover, wind normalized", () => {
    const a = skyAmounts({code: 0, wind_mph: 5, cloud_pct: 10})
    expect(a.rain).toBe(0)
    expect(a.snow).toBe(0)
    expect(a.bolt).toBe(0)
    expect(a.cloud).toBeCloseTo(0.1)
    expect(a.wind).toBeCloseTo(0.2)
  })

  test("heavy rain drives rain and implies cover past a stale cloud reading", () => {
    const a = skyAmounts({code: 65, wind_mph: 0, cloud_pct: 20})
    expect(a.rain).toBe(0.9)
    expect(a.cloud).toBeCloseTo(0.72) // rain * 0.8 beats 0.2
  })

  test("thunderstorm carries both bolt and rain", () => {
    const a = skyAmounts({code: 95, wind_mph: 30, cloud_pct: 90})
    expect(a.bolt).toBe(0.7)
    expect(a.rain).toBe(0.7)
    expect(a.wind).toBe(1) // capped
  })

  test("snow codes drive snow, not rain", () => {
    const a = skyAmounts({code: 73, wind_mph: 3, cloud_pct: 80})
    expect(a.snow).toBe(0.65)
    expect(a.rain).toBe(0)
  })

  test("fog forces a near-total veil", () => {
    const a = skyAmounts({code: 45, wind_mph: 0, cloud_pct: 30})
    expect(a.cloud).toBe(0.95)
  })

  test("missing fields fall back sanely", () => {
    const a = skyAmounts({})
    expect(a.rain).toBe(0)
    expect(a.cloud).toBeCloseTo(0.5)
    expect(a.wind).toBe(0)
  })
})

describe("localDayFrac", () => {
  test("noon UTC at UTC is 0.5", () => {
    expect(localDayFrac(86400 * 100 + 43200, 0)).toBeCloseTo(0.5)
  })

  test("applies the location's offset", () => {
    // Noon UTC at UTC-7 is 05:00 local.
    expect(localDayFrac(86400 * 100 + 43200, -25200)).toBeCloseTo(5 / 24)
  })

  test("wraps across midnight instead of going negative", () => {
    // 01:00 UTC at UTC-7 is 18:00 the previous local day.
    expect(localDayFrac(86400 * 100 + 3600, -25200)).toBeCloseTo(18 / 24)
  })

  test("treats a missing offset as UTC", () => {
    expect(localDayFrac(43200, undefined)).toBeCloseTo(0.5)
  })
})
