// Pure logic for the Clinch's management gate. No DOM, no Tauri — so it can be
// tested, which the hook itself cannot be (this repo has no DOM harness; see
// LEFTOVERS). The hook is the thin shell around these.

// Management runs through the desktop shell, not through LiveView. A plain
// browser — including one reached over an SSH tunnel — has no `__TAURI__`,
// because the runtime injects it into Tauri webviews rather than the loopback
// origin serving it. That absence is the honest UX boundary; the enforcement is
// that /api/clinch needs the full API token, which only the shell holds.
export function invoker(win = typeof window === "undefined" ? undefined : window) {
  return win?.__TAURI__?.core?.invoke || null
}

export function managementAvailable(win) {
  return invoker(win) !== null
}

// A credential's payload. `note` is optional and is deliberately separate from
// the value — the catalog description already warns never to put the secret in
// the note, and nothing here should make that easy to get wrong.
export function putPayload({kind, name, value, note}) {
  const cleanKind = (kind || "").trim()
  const cleanName = (name || "").trim().toLowerCase()
  const cleanNote = (note || "").trim()

  if (!cleanKind) return {error: "missing_kind"}
  if (!cleanName) return {error: "missing_name"}
  if (!value) return {error: "missing_value"}

  return {
    payload: {
      kind: cleanKind,
      name: cleanName,
      value,
      note: cleanNote === "" ? null : cleanNote,
    },
  }
}

export function deletePayload({kind, name}) {
  const cleanKind = (kind || "").trim()
  const cleanName = (name || "").trim().toLowerCase()

  if (!cleanKind) return {error: "missing_kind"}
  if (!cleanName) return {error: "missing_name"}

  return {payload: {kind: cleanKind, name: cleanName}}
}

// The app's error slugs, turned into something a person can act on. Anything
// unrecognized falls through as-is rather than being flattened to a generic
// message — a slug we have not seen is more useful than "something went wrong".
const MESSAGES = {
  missing_kind: "Pick what kind of credential this is.",
  missing_name: "Give it a name.",
  missing_value: "Enter the value.",
  missing_name_or_value: "A name and a value are both required.",
  unknown_kind: "That credential kind does not exist.",
  unmanaged_kind: "That kind cannot be stored here yet.",
  not_found: "There is nothing stored under that name.",
  invalid: "That name is not allowed: lowercase letters, digits, _ . and - only.",
  forbidden: "This build cannot manage credentials — the shell has no API token.",
  unauthorized: "This build cannot manage credentials — the shell has no API token.",
  unavailable: "Credentials can only be changed on the Mac running Buster Claw.",
}

export function errorMessage(slug) {
  if (!slug) return "Something went wrong."
  return MESSAGES[slug] || String(slug)
}

// A stored credential never comes back with its value, and the UI must not be
// able to display one by accident even if a future response carried it. This is
// belt-and-braces over the server contract, not a substitute for it.
export function safeEntry(entry) {
  if (!entry || typeof entry !== "object") return null
  const {kind, name, note} = entry
  return {kind: kind || null, name: name || null, note: note || null}
}
