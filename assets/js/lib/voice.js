// Spoken replies are OFF by default — a first-launch desktop user shouldn't
// have replies read aloud without opting in. The chat header's Voice toggle
// flips this localStorage flag; read fresh on every reply so toggling takes
// effect mid-run.
export function voiceOutEnabled() {
  return localStorage.getItem("bc:voice-out") === "on"
}

// Which voice to speak in, and how fast. Both are read fresh per reply for the
// same reason the toggle is: a change in Settings should land on the next line
// spoken, not the next launch.
//
// `null` means "whatever the Mac's System Settings are set to". That is the
// honest default for an app nobody has told what to sound like, and it is
// exactly how this behaved before there was a picker at all.
export const VOICE_NAME_KEY = "bc:voice-name"
export const VOICE_RATE_KEY = "bc:voice-rate"

export function voiceName() {
  const name = localStorage.getItem(VOICE_NAME_KEY)
  return name && name.trim() ? name : null
}

// Stored as a string; anything unparseable (hand-edited storage, a value from
// an older build) falls back to the system rate rather than to a guess.
export function voiceRate() {
  const rate = Number.parseInt(localStorage.getItem(VOICE_RATE_KEY) ?? "", 10)
  return Number.isFinite(rate) ? rate : null
}
