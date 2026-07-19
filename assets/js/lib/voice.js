// Spoken replies are OFF by default — a first-launch desktop user shouldn't
// have replies read aloud without opting in. The chat header's Voice toggle
// flips this localStorage flag; read fresh on every reply so toggling takes
// effect mid-run.
export function voiceOutEnabled() {
  return localStorage.getItem("bc:voice-out") === "on"
}
