// Spoken replies are on by default; the chat header's Voice toggle flips this
// localStorage flag. Read fresh on every reply so toggling takes effect mid-run.
export function voiceOutEnabled() {
  return localStorage.getItem("bc:voice-out") !== "off"
}
