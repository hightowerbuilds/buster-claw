import {
  voiceOutEnabled,
  voiceName,
  voiceRate,
  VOICE_NAME_KEY,
  VOICE_RATE_KEY,
} from "../lib/voice.js"

// Always-mounted bridge (layout header). Speaks assistant replies through the
// native macOS synthesizer via the Tauri `speak` command. The server pushes
// "bc:speak" for every assistant message; we gate on the Voice toggle and on
// running inside the desktop app (window.__TAURI__). "bc:stop_speak" (barge-in)
// and the local "bc:voice-stop" event (toggle turned off) cut speech short.
//
// The voice and rate are read per reply rather than captured at mount, so a
// change in Settings lands on the next line spoken instead of the next launch.
export const VoiceBridge = {
  mounted() {
    this.invoke = window.__TAURI__?.core?.invoke || null
    this.handleEvent("bc:speak", ({text}) => {
      if (!this.invoke || !voiceOutEnabled() || !text) return
      this.invoke("speak", {text, voice: voiceName(), rate: voiceRate()}).catch(() => {})
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
// (default OFF — see lib/voice.js) and reflects it in the button's
// styling/label. Turning it off also fires "bc:voice-stop" so the VoiceBridge
// cuts any reply already playing.
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

// What the app says when auditioning an English voice. A voice is being chosen
// for one job — reading replies — so the audition should be that job, not a
// generic "the quick brown fox".
const AUDITION_LINE = "Buster Claw here. This is how I'll read your replies."

// Settings → Voice. Lists the voices installed on THIS Mac (they are downloaded
// per-machine, so a hard-coded list would offer voices the operator does not
// have and hide the ones they went and fetched), persists the choice, and
// auditions it.
//
// Everything is client-side localStorage, matching how the Voice toggle already
// works — the server never learns which voice was picked, because nothing on the
// server needs to know.
export const VoicePicker = {
  mounted() {
    this.invoke = window.__TAURI__?.core?.invoke || null
    this.select = this.el.querySelector("[data-voice-select]")
    this.rate = this.el.querySelector("[data-voice-rate]")
    this.rateLabel = this.el.querySelector("[data-voice-rate-label]")
    this.audition = this.el.querySelector("[data-voice-audition]")
    this.reset = this.el.querySelector("[data-voice-reset]")
    this.controls = this.el.querySelector("[data-voice-controls]")
    this.unavailable = this.el.querySelector("[data-voice-unavailable]")

    // Outside the desktop app there is no synthesizer to drive, so say so
    // rather than rendering a picker that silently does nothing.
    if (!this.invoke) {
      if (this.unavailable) this.unavailable.hidden = false
      return
    }
    if (this.controls) this.controls.hidden = false

    this.onSelect = () => {
      const name = this.select.value
      if (name) localStorage.setItem(VOICE_NAME_KEY, name)
      else localStorage.removeItem(VOICE_NAME_KEY)
      this.play()
    }
    this.onRateInput = () => this.renderRate()
    // `change` rather than `input`: auditioning on every pixel of a drag would
    // queue a line per step.
    this.onRateChange = () => {
      localStorage.setItem(VOICE_RATE_KEY, this.rate.value)
      this.play()
    }
    this.onAudition = () => this.play()
    this.onReset = () => {
      localStorage.removeItem(VOICE_NAME_KEY)
      localStorage.removeItem(VOICE_RATE_KEY)
      this.render()
      this.play()
    }

    this.select?.addEventListener("change", this.onSelect)
    this.rate?.addEventListener("input", this.onRateInput)
    this.rate?.addEventListener("change", this.onRateChange)
    this.audition?.addEventListener("click", this.onAudition)
    this.reset?.addEventListener("click", this.onReset)

    this.load()
  },

  destroyed() {
    this.select?.removeEventListener("change", this.onSelect)
    this.rate?.removeEventListener("input", this.onRateInput)
    this.rate?.removeEventListener("change", this.onRateChange)
    this.audition?.removeEventListener("click", this.onAudition)
    this.reset?.removeEventListener("click", this.onReset)
  },

  async load() {
    let voices = []
    try {
      voices = await this.invoke("list_voices")
    } catch {
      voices = []
    }
    this.voices = Array.isArray(voices) ? voices : []
    this.render()
  },

  render() {
    if (!this.select) return

    // English first — the app's own copy is English, so those are the voices
    // most likely to be wanted — then by locale and name so the list is stable.
    const sorted = [...this.voices].sort((a, b) => {
      const aEn = a.locale.startsWith("en") ? 0 : 1
      const bEn = b.locale.startsWith("en") ? 0 : 1
      return aEn - bEn || a.locale.localeCompare(b.locale) || a.name.localeCompare(b.name)
    })

    this.select.replaceChildren()
    this.select.append(new Option("System default", ""))

    let group = null
    for (const voice of sorted) {
      if (!group || group.label !== voice.locale) {
        group = document.createElement("optgroup")
        group.label = voice.locale
        this.select.append(group)
      }
      group.append(new Option(voice.name, voice.name))
    }

    this.select.value = voiceName() ?? ""
    // A stored voice that is no longer installed would leave the select blank;
    // fall back to the visible truth rather than showing a lie.
    if (this.select.selectedIndex < 0) this.select.value = ""

    if (this.rate) this.rate.value = String(voiceRate() ?? 175)
    this.renderRate()
  },

  renderRate() {
    if (!this.rateLabel || !this.rate) return
    const stored = voiceRate()
    this.rateLabel.textContent =
      stored === null && this.rate.value === "175"
        ? "system default"
        : `${this.rate.value} words/min`
  },

  // Cut whatever is playing before previewing, so clicking through voices does
  // not build a queue of every one you auditioned on the way.
  play() {
    const name = this.select?.value || null
    const voice = this.voices.find((v) => v.name === name)
    const text = voice && !voice.locale.startsWith("en") ? voice.sample : AUDITION_LINE
    const rate = this.rate ? Number.parseInt(this.rate.value, 10) : null

    this.invoke("stop_speaking").catch(() => {})
    this.invoke("speak", {text, voice: name, rate: Number.isFinite(rate) ? rate : null}).catch(
      () => {},
    )
  },
}
