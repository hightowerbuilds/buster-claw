// Dialpad DTMF (SOUND_ROADMAP Phase 3) — WebAudio oscillator pairs on the
// Phone tab's keypad. Zero files and zero server round-trips: a keypad press
// is a user gesture, which is exactly the moment WebAudio is allowed to start,
// so there is no unlock dance and no latency beyond the oscillator itself.
//
// The frequency grid lives in ../lib/dtmf.js (tested); this hook is only the
// plumbing: one lazily-created shared AudioContext, and per press two
// oscillators through a gain envelope — 5ms in, 70ms hold, 20ms out, ~95ms
// total, quiet enough to sit under a voicemail playing in the same tab.
import {dtmfPair} from "../lib/dtmf.js"

const TONE_MS = 95
const GAIN = 0.12

export const Dtmf = {
  mounted() {
    this.ctx = null

    this.onDown = (event) => {
      // The master switch reaches the dialpad too. Mount-time snapshot: a
      // settings flip mid-session applies on next visit to the Phone tab,
      // which is the same freshness the rest of this page's assigns get.
      if (this.el.getAttribute("data-sound-on") !== "true") return

      const button = event.target.closest("[phx-value-key]")
      if (!button || !this.el.contains(button)) return

      const pair = dtmfPair(button.getAttribute("phx-value-key"))
      if (pair) this.beep(pair)
    }

    // pointerdown, not click: the tone belongs to the press, and on a real
    // phone it starts when your finger lands.
    this.el.addEventListener("pointerdown", this.onDown)
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onDown)
    this.ctx?.close().catch(() => {})
    this.ctx = null
  },

  beep([low, high]) {
    try {
      this.ctx = this.ctx || new (window.AudioContext || window.webkitAudioContext)()
      const ctx = this.ctx
      const t0 = ctx.currentTime

      const gain = ctx.createGain()
      gain.gain.setValueAtTime(0, t0)
      gain.gain.linearRampToValueAtTime(GAIN, t0 + 0.005)
      gain.gain.setValueAtTime(GAIN, t0 + (TONE_MS - 20) / 1000)
      gain.gain.linearRampToValueAtTime(0, t0 + TONE_MS / 1000)
      gain.connect(ctx.destination)

      for (const freq of [low, high]) {
        const osc = ctx.createOscillator()
        osc.type = "sine"
        osc.frequency.value = freq
        osc.connect(gain)
        osc.start(t0)
        osc.stop(t0 + TONE_MS / 1000)
        osc.addEventListener("ended", () => osc.disconnect())
      }
    } catch (_e) {
      // No AudioContext (ancient webview) or it refused — a silent dialpad is
      // the state it was in yesterday, not an error.
    }
  },
}
