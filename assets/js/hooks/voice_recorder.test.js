import {describe, expect, test} from "bun:test"
import {isArmed} from "./voice_recorder.js"

// The defect this pins (09-03-26): the reference recorder in Settings → Voice
// omits `data-armed`, because a recorder with nothing to type is always armed.
// `paint()` read that as armed and enabled the button; `start()` read it as
// disarmed and returned. The button looked live and did nothing — the failure
// mode with no error anywhere to find it by.
//
// The two call sites now share this function, so they cannot disagree again.
// These cases are the contract between this hook and BOTH of its markups.
describe("isArmed", () => {
  test("absent means armed — the Settings → Voice recorder never sets it", () => {
    expect(isArmed({})).toBe(true)
    expect(isArmed({eventTake: "reference_take"})).toBe(true)
  })

  test("the Studio's explicit \"false\" still disarms", () => {
    expect(isArmed({armed: "false"})).toBe(false)
  })

  test("the Studio's explicit \"true\" arms", () => {
    expect(isArmed({armed: "true"})).toBe(true)
  })

  // `dataset` is always present on a real element, but a hook that reads it
  // before `mounted()` has run should not throw its way out of a click.
  test("a missing dataset is armed rather than an exception", () => {
    expect(isArmed(undefined)).toBe(true)
    expect(isArmed(null)).toBe(true)
  })
})
