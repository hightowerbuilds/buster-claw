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

// Microphone device picker (Settings → Voice). Lists the Mac's input devices
// via the Tauri `list_input_devices` command and persists the choice to
// localStorage["bc:mic-device"], which the Mic hook reads when it records.
export const VoiceDevices = {
  mounted() {
    this.invoke = window.__TAURI__?.core?.invoke || null
    this.select = this.el.querySelector("[data-voice-device-select]")
    this.statusEl = this.el.querySelector("[data-voice-device-status]")
    this.refreshBtn = this.el.querySelector("[data-voice-device-refresh]")

    this.onChange = () => {
      const v = this.select ? this.select.value : ""
      if (v) localStorage.setItem("bc:mic-device", v)
      else localStorage.removeItem("bc:mic-device")
    }
    this.onRefresh = () => this.load()
    this.select?.addEventListener("change", this.onChange)
    this.refreshBtn?.addEventListener("click", this.onRefresh)
    this.load()
  },
  destroyed() {
    this.select?.removeEventListener("change", this.onChange)
    this.refreshBtn?.removeEventListener("click", this.onRefresh)
  },
  async load() {
    if (!this.invoke) {
      this.setStatus("Device selection is available in the desktop app.")
      return
    }
    this.setStatus("Finding microphones…")
    try {
      const devices = await this.invoke("list_input_devices")
      this.populate(Array.isArray(devices) ? devices : [])
    } catch (err) {
      this.setStatus("Could not list microphones: " + String(err?.message || err).slice(0, 120))
    }
  },
  populate(devices) {
    if (!this.select) return
    const saved = localStorage.getItem("bc:mic-device") || ""
    this.select.innerHTML = ""
    const def = document.createElement("option")
    def.value = ""
    def.textContent = "Default microphone"
    this.select.appendChild(def)

    let savedPresent = false
    for (const d of devices) {
      const opt = document.createElement("option")
      opt.value = d.name
      opt.textContent = d.is_default ? `${d.name} (default)` : d.name
      if (d.name === saved) { opt.selected = true; savedPresent = true }
      this.select.appendChild(opt)
    }
    // A previously-chosen device that's now unplugged falls back to default.
    if (saved && !savedPresent) {
      localStorage.removeItem("bc:mic-device")
      this.select.value = ""
    }
    const n = devices.length
    this.setStatus(n ? `${n} microphone${n === 1 ? "" : "s"} found.` : "No microphones found.")
  },
  setStatus(text) {
    if (this.statusEl) this.statusEl.textContent = text
  },
}

// Reusable voice-to-text mic. Self-contained so it can attach to ANY text
// input across the app (chat, terminal, browser, calendar): put phx-hook="Mic"
// on a button, point `data-voice-target` at the input's selector, and
// (optionally) `data-voice-overlay` at an element to flip visible while
// listening. Click to start, click again to stop; the on-device whisper
// transcript is appended to the target input (never auto-sent). Voice runs in
// the Tauri desktop shell — outside it, a click reports a friendly notice.
export const Mic = {
  mounted() {
    this.invoke = window.__TAURI__?.core?.invoke || null
    this.target = this.resolve(this.el.dataset.voiceTarget)
    this.overlay = this.resolve(this.el.dataset.voiceOverlay)
    this.idleIcon = this.el.querySelector("[data-mic-idle]")
    this.busyIcon = this.el.querySelector("[data-mic-busy]")
    this.state = "idle"

    this.onClick = (e) => { e.preventDefault(); this.toggle() }
    this.el.addEventListener("click", this.onClick)
    // ⌘/ (or Ctrl+/) toggles too, for keyboard users.
    this.onHotkey = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "/" && !e.repeat) {
        e.preventDefault()
        this.toggle()
      }
    }
    window.addEventListener("keydown", this.onHotkey)
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    window.removeEventListener("keydown", this.onHotkey)
    this.setOverlay(false)
  },
  // Resolve a selector, preferring a match inside the same form so multiple
  // mics on a page each bind to their own input.
  resolve(sel) {
    if (!sel) return null
    const root = this.el.closest("form") || document
    return root.querySelector(sel) || document.querySelector(sel)
  },
  toggle() {
    if (this.state === "idle") this.start()
    else if (this.state === "listening") this.stop()
    // "transcribing" is a brief, non-interactive window — ignore clicks.
  },
  async start() {
    if (!this.invoke) {
      this.notify("Voice input is only available in the desktop app.")
      return
    }
    // Don't transcribe our own spoken reply: cut any TTS first.
    this.invoke("stop_speaking").catch(() => {})
    this.setState("listening")
    try {
      // Use the device chosen in Settings → Voice, else the system default.
      const device = localStorage.getItem("bc:mic-device") || null
      await this.invoke("start_recording", {device})
    } catch (err) {
      this.setState("idle")
      this.error(err)
    }
  },
  async stop() {
    if (!this.invoke) return
    this.setState("transcribing")
    try {
      const res = await this.invoke("stop_recording")
      this.insert(res && res.text)
    } catch (err) {
      this.error(err)
    } finally {
      this.setState("idle")
    }
  },
  insert(text) {
    const t = (text || "").trim()
    if (!t || !this.target) return
    const cur = this.target.value || ""
    this.target.value = cur && !/\s$/.test(cur) ? cur + " " + t : cur + t
    // Let LiveView / other listeners see the change (e.g. send-button enable).
    this.target.dispatchEvent(new Event("input", {bubbles: true}))
    this.target.focus()
    const end = this.target.value.length
    if (this.target.setSelectionRange) this.target.setSelectionRange(end, end)
  },
  setState(state) {
    this.state = state
    this.el.dataset.state = state
    const busy = state === "transcribing"
    if (this.idleIcon) this.idleIcon.hidden = busy
    if (this.busyIcon) this.busyIcon.hidden = !busy
    this.el.style.pointerEvents = busy ? "none" : ""
    if (state === "listening") this.el.setAttribute("aria-pressed", "true")
    else this.el.removeAttribute("aria-pressed")
    this.setOverlay(state === "listening")
  },
  setOverlay(on) {
    if (this.overlay) this.overlay.hidden = !on
  },
  notify(message) {
    this.pushEvent("voice_error", {message})
  },
  error(err) {
    const raw = String(err && err.message ? err.message : err)
    const denied = /denied|authoriz|permission|not authorized/i.test(raw)
    this.notify(
      denied
        ? "Microphone access denied — enable it in System Settings › Privacy & Security › Microphone."
        : "Voice input failed: " + raw.slice(0, 160)
    )
  },
}
