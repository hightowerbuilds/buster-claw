import {describe, expect, test} from "bun:test"
import {auditionPlan, planEndMs, playheadRatio} from "./audition.js"

describe("auditionPlan", () => {
  test("plays clips on audible tracks, in place", () => {
    const plan = auditionPlan([
      {audible: true, clips: [{src: "/a.wav", startMs: 0}, {src: "/b.wav", startMs: 500}]},
    ])

    expect(plan).toEqual([
      {src: "/a.wav", startMs: 0},
      {src: "/b.wav", startMs: 500},
    ])
  })

  test("a silenced track contributes nothing — mute must not render OR audition", () => {
    const plan = auditionPlan([
      {audible: false, clips: [{src: "/loud.wav", startMs: 0}]},
      {audible: true, clips: [{src: "/keep.wav", startMs: 100}]},
    ])

    expect(plan).toEqual([{src: "/keep.wav", startMs: 100}])
  })

  test("a clip with no source is skipped, not a crash", () => {
    // The render refuses loudly on a missing source; the audition plays what
    // exists, so the arrangement can be FIXED around the dead reference.
    const plan = auditionPlan([
      {audible: true, clips: [{src: null, startMs: 0}, {src: "/ok.wav", startMs: 0}]},
    ])

    expect(plan).toEqual([{src: "/ok.wav", startMs: 0}])
  })

  test("negative offsets clamp to the start, mirroring the schema", () => {
    const plan = auditionPlan([{audible: true, clips: [{src: "/x.wav", startMs: -300}]}])
    expect(plan[0].startMs).toBe(0)
  })

  test("an empty or absent score is an empty plan", () => {
    expect(auditionPlan([])).toEqual([])
    expect(auditionPlan(null)).toEqual([])
    expect(auditionPlan([{audible: true, clips: []}])).toEqual([])
  })
})

describe("planEndMs", () => {
  test("the end is the furthest clip's far edge, not the last clip's", () => {
    const durations = new Map([
      ["/long.wav", 2000],
      ["/short.wav", 100],
    ])

    const end = planEndMs(
      [
        {src: "/long.wav", startMs: 0},
        {src: "/short.wav", startMs: 1500},
      ],
      durations
    )

    expect(end).toBe(2000)
  })

  test("an unknown duration counts as zero rather than poisoning the total", () => {
    const end = planEndMs([{src: "/ghost.wav", startMs: 400}], new Map())
    expect(end).toBe(400)
  })

  test("an empty plan ends immediately", () => {
    expect(planEndMs([], new Map())).toBe(0)
  })
})

describe("playheadRatio", () => {
  test("clamps both ends — a stall never draws past the end", () => {
    expect(playheadRatio(-50, 1000)).toBe(0)
    expect(playheadRatio(500, 1000)).toBe(0.5)
    expect(playheadRatio(9999, 1000)).toBe(1)
  })

  test("a zero-length performance is already over", () => {
    expect(playheadRatio(0, 0)).toBe(1)
  })
})
