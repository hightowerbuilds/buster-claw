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

// What a keydown means to the Notes panel. Returns one of:
//
//   "switcher"  open the ⌘P jump list
//   "new"       start a new note (⌘N)
//   "close"     close the switcher
//   "up"/"down" move the switcher's selection
//   "select"    open the highlighted result
//   null        not ours — let the event through
//
// Typing contexts are deliberately NOT excluded. ⌘P and ⌘N are print and
// new-window: an editor is expected to claim them, and the moment you most want
// "jump to another note" is halfway through typing a sentence. The navigation
// keys are claimed only while the switcher is open, so arrows and Enter keep
// their ordinary meaning in the textarea the rest of the time.
//
// ⌘S is checked first and rejected: it belongs to the editor hook, and claiming
// it in both places would submit the form twice.
export function notesIntent(event, {switcherOpen} = {}) {
  if (!event || typeof event.key !== "string") return null
  if (isSaveChord(event)) return null

  const mod = event.metaKey || event.ctrlKey
  const key = event.key.toLowerCase()

  if (mod && key === "p") return "switcher"
  if (mod && key === "n") return "new"

  if (!switcherOpen) return null

  switch (event.key) {
    case "Escape":
      return "close"
    case "ArrowDown":
      return "down"
    case "ArrowUp":
      return "up"
    case "Enter":
      return "select"
    default:
      return null
  }
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

// Which formatting command a keydown asks for, or null.
//
// Three chords, and only three. ⌘B, ⌘I and ⌘K mean the same thing in every
// editor a person has used, so claiming them is expected rather than rude. The
// other eleven toolbar commands get no chord: a shortcut for "numbered list"
// that nobody can guess is a line in a manual nobody reads, and it costs a
// keystroke the browser or the OS may want.
//
// ⌘S is rejected first for the same reason it is in `notesIntent` — it belongs
// to the save path, and a near-miss that formats instead of saving would be a
// genuinely bad surprise.
const FORMAT_CHORDS = {b: "bold", i: "italic", k: "link"}

export function formatChord(event) {
  if (!event || typeof event.key !== "string") return null
  if (!(event.metaKey || event.ctrlKey)) return null
  if (isSaveChord(event)) return null
  // ⌥⌘B and friends belong to the OS and to the browser's own menus.
  if (event.altKey) return null

  return FORMAT_CHORDS[event.key.toLowerCase()] || null
}
