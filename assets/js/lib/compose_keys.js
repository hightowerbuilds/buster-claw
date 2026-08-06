// The chat composer's keyboard contract, as a pure function.
//
// Extracted because there are two composers — Home's docked panel (`AgentChat`)
// and Trading's floating windows (`ChatWindow`) — and they had two independent
// copies of "Enter sends, Shift+Enter is a newline" already. A third rule was
// about to be added to both, and the failure mode of a drifted copy here is
// invisible: one surface silently keeps steering, the other silently queues.
//
// The contract:
//
//   Enter                    submit the PRIMARY action
//   Shift+Enter              newline (never submits)
//   Cmd/Ctrl+Shift+Enter     submit the SECONDARY action, once
//
// The third row exists because the primary action changes with the backend and
// with whether a run is active. An operator who wants "after that, run the
// tests" while the primary says **Steer now** needs a way to say so without
// reaching for the mouse — and the inverse, once steering is the default.

// What a keydown in the composer means. Returns one of:
//
//   "primary"    submit using the composer's primary delivery
//   "secondary"  submit using the other one, for this message only
//   "newline"    insert a line break; do not submit
//   null         not our business — let the event through
//
// `Shift+Enter` is checked BEFORE the modifier combination on purpose: a plain
// Shift+Enter must always be a newline, and only the presence of Cmd or Ctrl
// promotes it to the inverted submit.
export function composeIntent(event) {
  if (!event || event.key !== "Enter") return null

  // IME composition: Enter is confirming a candidate, not sending a message.
  // Submitting here truncates what the user was typing, which is why this is
  // checked before anything else.
  if (event.isComposing || event.keyCode === 229) return null

  const chord = event.metaKey || event.ctrlKey

  if (chord && event.shiftKey) return "secondary"
  if (event.shiftKey) return "newline"
  if (chord) return null

  if (event.altKey) return "newline"

  return "primary"
}

// The delivery mode a submission should carry.
//
// `primary` is what the composer's main button does right now; `secondary` is
// the other one. Kept here rather than in the hooks so the button label, the
// keyboard chord, and the value posted to the server cannot disagree.
//
//   running + steerable   ->  primary :steer,  secondary :next
//   running, not steerable->  primary :next,   secondary :next
//   idle                  ->  primary :auto,   secondary :auto
//
// Idle collapses to `auto` for both because there is no active turn to steer
// into and nothing to queue behind: every mode starts a turn, and offering a
// choice that changes nothing would be a lie told by a button.
export function deliveryFor({running, steerable}, which = "primary") {
  if (!running) return "auto"

  if (!steerable) return "next"

  return which === "secondary" ? "next" : "steer"
}

// The label for the composer's primary action, given the same state. A backend
// that cannot steer must not offer a Steer button that silently queues — the
// roadmap's "no placebo" rule.
export function primaryLabel({running, steerable}) {
  if (!running) return "Send"
  return steerable ? "Steer now" : "Queue next"
}

// The secondary action, or null when there is nothing distinct to offer.
export function secondaryLabel({running, steerable}) {
  if (!running || !steerable) return null
  return "Queue next"
}
