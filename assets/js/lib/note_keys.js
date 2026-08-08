// The Notes editor's two decisions, as pure functions.
//
// The `NoteEditor` hook is all DOM and listeners, which the Elixir suite cannot
// see at all — `render_hook/3` pushes straight at the component and never loads
// this file. What CAN be tested is the part that decides, so it lives here and
// the hook only wires it up.

// Whether a keydown is the save chord. ⌘S on macOS, Ctrl+S everywhere else;
// the browser's "save this page" is not useful inside an editor and taking it
// is what every editor does.
//
// Shift and Alt are deliberately NOT excluded — ⇧⌘S is nobody's "save as" here,
// and a near-miss chord that silently does nothing is worse than saving.
export function isSaveChord(event) {
  if (!event || typeof event.key !== "string") return false
  if (!(event.metaKey || event.ctrlKey)) return false

  return event.key.toLowerCase() === "s"
}

// Whether a keystroke should tell the server the draft is now ahead of disk.
//
// Two suppressions, both load-bearing:
//
//   * already dirty — the server said `Unsaved` once and nothing changes it
//     back until a save lands, so per-keystroke pushes would be pure noise on
//     top of the debounce this exists to paper over.
//   * conflict — autosave has STOPPED, and the banner explaining that is the
//     status. Re-announcing dirt would replace the explanation with a state
//     that implies a save is still coming.
export function shouldAnnounceDirty({dirty, state}) {
  if (dirty) return false
  if (state === "conflict") return false

  return true
}
