import {test, expect} from "bun:test"
import {WorkbenchAreas} from "./workbench_areas.js"
import {WorkbenchDrag} from "./workbench_drag.js"
import {registerTerminal, unregisterTerminal} from "../lib/tabs.js"

function withWindow(run) {
  const prior = globalThis.window
  globalThis.window = {dispatchEvent() {}, removeEventListener() {}}
  try { run() } finally { globalThis.window = prior }
}
function hook() {
  return {
    state: {active_area_id: "area-1", revision: 2, active: "chat"},
    storage: {setItem() {}}, draw() {}, notice() {},
    stopDrag() {this.drag = null},
    dropPane(cancelled, commit) {this.cancelled = {cancelled, commit}; this.paneDrag = null},
    ...WorkbenchAreas,
  }
}

test("focus acknowledgements wait for a gesture, but a newer layout cancels stale movement", () => withWindow(() => {
  const h = hook()
  h.paneDrag = {key: "chat"}
  const focus = {...h.state, active: "notes"}
  h.receiveState(focus)
  expect(h.pendingState).toBe(focus)
  expect(h.state.active).toBe("chat")
  const next = {...focus, revision: 3, mode: "grid"}
  h.receiveState(next)
  expect(h.cancelled).toEqual({cancelled: true, commit: false})
  expect(h.state).toBe(next)
  expect(h.pendingState).toBeNull()
}))

test("a final divider acknowledgement clears a deferred focus update", () => withWindow(() => {
  const h = hook()
  h.pendingState = {...h.state, active: "old"}
  const committed = {...h.state, revision: 3}
  h.receiveState(committed)
  expect(h.state).toBe(committed)
  expect(h.pendingState).toBeNull()
}))

test("release keeps the moved frame through a focus acknowledgement; cancel restores its start", () => withWindow(() => {
  for (const cancelled of [false, true]) {
    const startFrame = {x: 0.1, y: 0.1, width: 0.7, height: 0.7}
    const frame = {...startFrame, x: 0.2}
    const h = {...hook(), ...WorkbenchDrag, root: {dataset: {}}, pushEvent(name, params) {this.sent = {name, params}}}
    h.state = {...h.state, frames: {chat: frame}}
    h.pendingState = {...h.state, frames: {chat: startFrame}}
    h.paneDrag = {key: "chat", mode: "overlap", frame, startFrame, lifted: true,
      area_id: "area-1", revision: 2,
      pane: {removeEventListener() {}, releasePointerCapture() {}, classList: {remove() {}}}}
    h.dropPane(cancelled)
    expect(h.state.frames.chat).toEqual(cancelled ? startFrame : frame)
    expect(h.sent).toEqual({name: "workbench_move", params: {
      key: "chat", frame: cancelled ? startFrame : frame, area_id: "area-1", revision: 2}})
  }
}))

async function closeFixture(busy, run) {
  const calls = []
  const terminals = ["terminal", "terminal-2"].map(key => ({
    el: {key},
    async isBusy() {calls.push(`probe:${key}`); return key === "terminal" || busy},
    async closeSession() {calls.push(`close:${key}`)},
  }))
  terminals.forEach(registerTerminal)
  const h = {...hook(),
    state: {areas: [{id: "area-1", tree: "terminal"}, {id: "area-2", tree: "terminal-2"}]},
    canvas: {querySelector(selector) {return {contains(el) {return selector.includes(`"${el.key}"`)}}}},
    pushEvent(name, params) {calls.push({name, params})},
  }
  try {await run(h, calls)} finally {terminals.forEach(unregisterTerminal)}
}

test("closing an idle background area leaves another area's busy terminal untouched", async () => {
  await closeFixture(false, async (h, calls) => {
    await h.closeArea("area-1")
    expect(calls).toEqual([])
    await h.closeArea("area-2")
    expect(calls).toEqual(["probe:terminal-2", "close:terminal-2",
      {name: "workbench_close_area", params: {id: "area-2"}}])
  })
})

test("busy area cancellation keeps its sessions; confirmation closes only its terminals", async () => {
  const prior = globalThis.document
  try {
    for (const key of ["Escape", "Enter"]) {
      let answer
      globalThis.document = {
        createElement() {return {setAttribute() {}, addEventListener() {}, remove() {}, querySelector() {return null}}},
        addEventListener(_name, listener) {answer = listener}, removeEventListener() {},
        body: {appendChild() {queueMicrotask(() => answer({key, preventDefault() {}, stopPropagation() {}}))}},
      }
      await closeFixture(true, async (h, calls) => {
        await h.closeArea("area-2")
        expect(calls).toEqual(key === "Escape" ? ["probe:terminal-2"] :
          ["probe:terminal-2", "close:terminal-2", {name: "workbench_close_area", params: {id: "area-2"}}])
        expect(h.closingArea).toBe(false)
      })
    }
  } finally {globalThis.document = prior}
})
