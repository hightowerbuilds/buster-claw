import {describe, expect, test} from "bun:test"
import {buttonLabel, clickAction, isArmed, micBlockedHere, VoiceRecorder} from "./voice_recorder.js"

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

// The defect these pin (09-13-26): the hook opened the microphone in mounted(),
// so rendering the recorder WAS a microphone request. In `cargo tauri dev` —
// a bare binary with no usage description — macOS TCC answers that by killing
// the app, and the recorder sits on the Vox tab's default page. Every click on
// the tab crashed the whole app.

// Just enough of an element for mounted() and paint(): the data-role children
// the hook looks up, each able to take a style, a label and a listener.
function fakeElement(dataset) {
  const node = () => ({
    style: {},
    dataset: {},
    textContent: "",
    disabled: false,
    classList: {add() {}, remove() {}},
    addEventListener() {},
    removeEventListener() {},
  })
  const roles = {
    record: node(), meter: node(), peak: node(), clip: node(),
    format: node(), "target-zone": node(), status: node(),
  }
  return {
    dataset,
    querySelector(selector) {
      const role = selector.match(/data-role="([^"]+)"/)?.[1]
      return roles[role] || null
    },
  }
}

function hookFor(dataset) {
  const pushed = []
  const hook = Object.assign(Object.create(VoiceRecorder), {
    el: fakeElement(dataset),
    pushEventTo: (_el, event, payload) => pushed.push({event, payload}),
  })
  return {hook, pushed}
}

describe("the microphone opens on a click, never on mount", () => {
  test("mounting does not open it, and the button offers to", () => {
    const {hook} = hookFor({eventReport: "reference_report"})
    let opened = 0
    hook.open = () => { opened += 1 }

    hook.mounted()

    expect(opened).toBe(0)
    expect(hook.els.record.textContent).toBe("Turn on microphone")
    expect(hook.els.record.disabled).toBe(false)

    hook.onClick()
    expect(opened).toBe(1)
  })

  // The Studio arms Record only once a word is typed. Turning the microphone on
  // keeps nothing, and checking your level before you type is V.6's whole point.
  test("a disarmed recorder can still turn the microphone on", () => {
    const {hook} = hookFor({armed: "false"})
    hook.open = () => {}
    hook.mounted()
    expect(hook.els.record.disabled).toBe(false)
  })

  test("one button walks open, record, stop", () => {
    expect(clickAction({open: false, recording: false})).toBe("open")
    expect(clickAction({open: true, recording: false})).toBe("start")
    expect(clickAction({open: true, recording: true})).toBe("stop")

    expect(buttonLabel({open: false, recording: false})).toBe("Turn on microphone")
    expect(buttonLabel({open: true, recording: false})).toBe("● Record")
    expect(buttonLabel({open: true, recording: true})).toBe("■ Stop")
  })
})

describe("the dev desktop window refuses instead of asking", () => {
  test("only Tauri talking to a dev server is blocked", () => {
    const tauri = {__TAURI__: {core: {}}}
    expect(micBlockedHere(tauri, {devServer: "true"})).toBe(true)
    // A packaged app runs a release, and its window carries a usage description.
    expect(micBlockedHere(tauri, {devServer: "false"})).toBe(false)
    expect(micBlockedHere(tauri, {})).toBe(false)
    // A browser at 127.0.0.1:4000 has its own microphone grant.
    expect(micBlockedHere({}, {devServer: "true"})).toBe(false)
    expect(micBlockedHere(undefined, undefined)).toBe(false)
  })

  // Order matters, not just the predicate: the refusal has to happen BEFORE the
  // microphone API is touched. Were the check moved below it, bun (which has no
  // mediaDevices) would report "unsupported" here instead, and this would fail.
  test("turning the mic on reports unbundled and opens nothing", async () => {
    const {hook, pushed} = hookFor({devServer: "true", eventReport: "reference_report"})
    hook.mounted()

    const had = Object.prototype.hasOwnProperty.call(globalThis, "__TAURI__")
    globalThis.__TAURI__ = {core: {}}
    try {
      await hook.open()
    } finally {
      if (!had) delete globalThis.__TAURI__
    }

    expect(pushed.map((p) => [p.event, p.payload.do, p.payload.state])).toEqual([
      ["reference_report", "capability", "unbundled"],
    ])
    expect(hook.stream).toBeFalsy()
  })
})
