// Shared keyboard-shortcut predicates.
//
// Extracted when the Studio's arranger needed the same "is the user typing?"
// test the music player already made for Space. Two copies of this rule would
// drift, and the failure mode is quiet and infuriating: a shortcut that eats a
// character out of a text field, or one that stops firing because only one copy
// learned about a new element type.

// Whether a key event came from somewhere the user is entering text, and so is
// none of a shortcut's business.
//
// `SELECT` is included because typing a letter in a dropdown jumps to the
// matching option, and `contenteditable` because rich-text areas are neither an
// input nor a textarea. Textarea also covers **xterm**, whose hidden input
// helper is one — the terminal must keep every chord it defines.
export function isTypingContext(target) {
  if (!target) return false

  return (
    target.tagName === "INPUT" ||
    target.tagName === "TEXTAREA" ||
    target.tagName === "SELECT" ||
    target.isContentEditable === true
  )
}
