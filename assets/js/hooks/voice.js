import {voiceOutEnabled} from "../lib/voice.js"

// Always-mounted bridge (layout header). Speaks assistant replies through the
// native macOS synthesizer via the Tauri `speak` command. The server pushes
// "bc:speak" for every assistant message; we gate on the Voice toggle and on
// running inside the desktop app (window.__TAURI__). "bc:stop_speak" (barge-in)
// and the local "bc:voice-stop" event (toggle turned off) cut speech short.
export const VoiceBridge = {
  mounted() {
    this.invoke = window.__TAURI__?.core?.invoke || null
    this.handleEvent("bc:speak", ({text}) => {
      if (!this.invoke || !voiceOutEnabled() || !text) return
      this.invoke("speak", {text}).catch(() => {})
    })
    this.handleEvent("bc:stop_speak", () => this.stop())
    this.onStop = () => this.stop()
    window.addEventListener("bc:voice-stop", this.onStop)
  },
  destroyed() {
    window.removeEventListener("bc:voice-stop", this.onStop)
  },
  stop() {
    if (this.invoke) this.invoke("stop_speaking").catch(() => {})
  },
}

// The chat header's "Voice on/off" toggle. Persists the choice in localStorage
// (default on) and reflects it in the button's styling/label. Turning it off
// also fires "bc:voice-stop" so the VoiceBridge cuts any reply already playing.
export const VoiceToggle = {
  mounted() {
    this.label = this.el.querySelector("[data-voice-label]")
    this.onClick = () => {
      const on = !this.isOn()
      localStorage.setItem("bc:voice-out", on ? "on" : "off")
      if (!on) window.dispatchEvent(new Event("bc:voice-stop"))
      this.render()
    }
    this.el.addEventListener("click", this.onClick)
    this.render()
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },
  isOn() {
    return voiceOutEnabled()
  },
  render() {
    const on = this.isOn()
    this.el.setAttribute("aria-pressed", String(on))
    this.el.classList.toggle("border-primary", on)
    this.el.classList.toggle("text-primary", on)
    this.el.classList.toggle("border-base-content/20", !on)
    this.el.classList.toggle("text-base-content/40", !on)
    if (this.label) this.label.textContent = on ? "Voice on" : "Voice off"
  },
}
