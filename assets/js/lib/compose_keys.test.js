import {expect, test, describe} from "bun:test"
import {composeIntent, deliveryFor, primaryLabel, secondaryLabel} from "./compose_keys.js"

const key = (extra = {}) => ({key: "Enter", ...extra})

describe("composeIntent", () => {
  test("Enter submits the primary action", () => {
    expect(composeIntent(key())).toBe("primary")
  })

  test("Shift+Enter is a newline and never submits", () => {
    expect(composeIntent(key({shiftKey: true}))).toBe("newline")
  })

  test("Cmd/Ctrl+Shift+Enter inverts to the secondary action", () => {
    expect(composeIntent(key({metaKey: true, shiftKey: true}))).toBe("secondary")
    expect(composeIntent(key({ctrlKey: true, shiftKey: true}))).toBe("secondary")
  })

  test("a bare modifier+Enter is left alone", () => {
    // Cmd+Enter is a submit chord in plenty of apps, but claiming it here would
    // make Cmd+Shift+Enter ambiguous with a slipped finger.
    expect(composeIntent(key({metaKey: true}))).toBe(null)
    expect(composeIntent(key({ctrlKey: true}))).toBe(null)
  })

  test("Option/Alt+Enter is a newline, matching the platform habit", () => {
    expect(composeIntent(key({altKey: true}))).toBe("newline")
  })

  test("any other key is none of our business", () => {
    expect(composeIntent({key: "a"})).toBe(null)
    expect(composeIntent({key: "Escape"})).toBe(null)
    expect(composeIntent(null)).toBe(null)
  })

  test("Enter during IME composition confirms a candidate, it does not send", () => {
    // Submitting here truncates what the user was mid-way through typing.
    expect(composeIntent(key({isComposing: true}))).toBe(null)
    expect(composeIntent(key({keyCode: 229}))).toBe(null)
  })
})

describe("deliveryFor", () => {
  test("an idle composer always starts a turn, whichever action is used", () => {
    // There is no active turn to steer into and nothing to queue behind, so a
    // choice here would change nothing and say otherwise.
    expect(deliveryFor({running: false, steerable: true})).toBe("auto")
    expect(deliveryFor({running: false, steerable: true}, "secondary")).toBe("auto")
    expect(deliveryFor({running: false, steerable: false})).toBe("auto")
  })

  test("a running, steerable backend steers by default and queues on the chord", () => {
    expect(deliveryFor({running: true, steerable: true})).toBe("steer")
    expect(deliveryFor({running: true, steerable: true}, "secondary")).toBe("next")
  })

  test("a running backend that cannot steer only ever queues", () => {
    // No placebo: the chord must not post `steer` to a backend that would
    // silently turn it into a queued message.
    expect(deliveryFor({running: true, steerable: false})).toBe("next")
    expect(deliveryFor({running: true, steerable: false}, "secondary")).toBe("next")
  })
})

describe("labels", () => {
  test("the primary action names what will actually happen", () => {
    expect(primaryLabel({running: false, steerable: true})).toBe("Send")
    expect(primaryLabel({running: true, steerable: true})).toBe("Steer now")
    expect(primaryLabel({running: true, steerable: false})).toBe("Queue next")
  })

  test("a secondary action is offered only when it differs from the primary", () => {
    expect(secondaryLabel({running: true, steerable: true})).toBe("Queue next")
    expect(secondaryLabel({running: true, steerable: false})).toBe(null)
    expect(secondaryLabel({running: false, steerable: true})).toBe(null)
  })

  test("the label and the delivery it posts never disagree", () => {
    for (const running of [true, false]) {
      for (const steerable of [true, false]) {
        const state = {running, steerable}
        const label = primaryLabel(state)
        const delivery = deliveryFor(state, "primary")

        if (label === "Steer now") expect(delivery).toBe("steer")
        if (label === "Queue next") expect(delivery).toBe("next")
        if (label === "Send") expect(delivery).toBe("auto")
      }
    }
  })
})
