import {test, expect, describe} from "bun:test"
import {
  invoker,
  managementAvailable,
  putPayload,
  deletePayload,
  errorMessage,
  safeEntry,
} from "./clinch.js"

const tauriWindow = {__TAURI__: {core: {invoke: () => {}}}}
const plainWindow = {}

describe("management availability", () => {
  test("a Tauri webview can manage credentials", () => {
    expect(managementAvailable(tauriWindow)).toBe(true)
    expect(typeof invoker(tauriWindow)).toBe("function")
  })

  // The boundary the whole Phase 2 design rests on: a browser reached over an
  // SSH tunnel is a plain browser. It loads the same origin and the same HTML,
  // and it still has no IPC bridge, because the runtime injects __TAURI__ into
  // Tauri webviews rather than the page being served it.
  test("a plain browser cannot, however it reached the page", () => {
    expect(managementAvailable(plainWindow)).toBe(false)
    expect(invoker(plainWindow)).toBe(null)
    expect(managementAvailable(undefined)).toBe(false)
    expect(managementAvailable({__TAURI__: {}})).toBe(false)
    expect(managementAvailable({__TAURI__: {core: {}}})).toBe(false)
  })
})

describe("putPayload", () => {
  test("normalizes the name the same way the server does", () => {
    const {payload} = putPayload({kind: "sign_in", name: "  ACME-Login  ", value: "s"})
    expect(payload.name).toBe("acme-login")
  })

  test("carries the value through untouched", () => {
    const value = "  a password with spaces  "
    const {payload} = putPayload({kind: "sign_in", name: "n", value})
    expect(payload.value).toBe(value)
  })

  test("an empty note becomes null rather than an empty string", () => {
    expect(putPayload({kind: "sign_in", name: "n", value: "v"}).payload.note).toBe(null)
    expect(putPayload({kind: "sign_in", name: "n", value: "v", note: "   "}).payload.note).toBe(
      null,
    )
    expect(putPayload({kind: "sign_in", name: "n", value: "v", note: " hi "}).payload.note).toBe(
      "hi",
    )
  })

  test("refuses incomplete input before anything is sent", () => {
    expect(putPayload({name: "n", value: "v"}).error).toBe("missing_kind")
    expect(putPayload({kind: "sign_in", value: "v"}).error).toBe("missing_name")
    expect(putPayload({kind: "sign_in", name: "n"}).error).toBe("missing_value")
    expect(putPayload({kind: "sign_in", name: "n", value: ""}).error).toBe("missing_value")
  })

  test("a whitespace-only value is still a value — only empty is refused", () => {
    expect(putPayload({kind: "sign_in", name: "n", value: " "}).payload.value).toBe(" ")
  })
})

describe("deletePayload", () => {
  test("normalizes and validates", () => {
    expect(deletePayload({kind: "sign_in", name: " ACME "}).payload).toEqual({
      kind: "sign_in",
      name: "acme",
    })
    expect(deletePayload({kind: "sign_in"}).error).toBe("missing_name")
    expect(deletePayload({name: "n"}).error).toBe("missing_kind")
  })
})

describe("errorMessage", () => {
  test("maps the app's slugs to something actionable", () => {
    expect(errorMessage("not_found")).toMatch(/nothing stored/)
    expect(errorMessage("unmanaged_kind")).toMatch(/cannot be stored/)
    expect(errorMessage("forbidden")).toMatch(/no API token/)
  })

  test("passes an unknown slug through instead of flattening it", () => {
    expect(errorMessage("some_new_slug")).toBe("some_new_slug")
    expect(errorMessage(null)).toBe("Something went wrong.")
  })
})

describe("safeEntry", () => {
  // Belt and braces over the server contract. The controller already never
  // serializes a value; this makes it so a future response that did could not
  // be rendered by accident.
  test("keeps only kind, name and note — never a value", () => {
    const entry = safeEntry({kind: "sign_in", name: "acme", note: "n", value: "LEAKED"})

    expect(entry).toEqual({kind: "sign_in", name: "acme", note: "n"})
    expect(JSON.stringify(entry)).not.toContain("LEAKED")
  })

  test("handles nothing gracefully", () => {
    expect(safeEntry(null)).toBe(null)
    expect(safeEntry("nope")).toBe(null)
    expect(safeEntry({})).toEqual({kind: null, name: null, note: null})
  })
})
