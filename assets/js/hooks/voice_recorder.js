// The in-app recorder — the only path in this app that opens a microphone
// (STUDIO_ROADMAP V.6-V.8).
//
// WHY CAPTURE HAPPENS HERE AND NOT IN THE BEAM. Entitlements do not inherit
// across process boundaries, so the process that opens the microphone is the
// process that needs the TCC grant. Capturing in the WebView puts that in the
// signed Tauri app, which carries an Info.plist and an Entitlements.plist.
// Spawning ffmpeg from the BEAM puts it in a process with neither, where consent
// is attributed to the responsible process — and the failure mode there is the
// worst available: a WAV full of digital silence, exit code 0, no prompt, no
// error. That was measured on 08-09, and it is why `sound_record` refuses a
// silent take rather than storing one.
//
// AN AUDIOWORKLET, NOT MediaRecorder. Three reasons, all load-bearing:
//   1. CSP. MediaRecorder produces a Blob whose natural next step is
//      URL.createObjectURL, and with no media-src this app falls back to
//      default-src 'self', where blob: media is refused.
//   2. Format. MediaRecorder emits MP4/AAC in WKWebView and WebM/Opus in
//      Chrome — both lossy, and THE TWO HOSTS WOULD DISAGREE, which is
//      intolerable for a corpus whose whole purpose is comparing takes.
//   3. We already have the encoder. Raw Float32 goes to the server and
//      SoundStudio.write/2 makes the WAV with tested Elixir.
//
// THE CAPABILITY ANSWER IS PUSHED BACK, NOT ASSUMED. V.4a — does getUserMedia
// work in a packaged build? — has never been run. So this probes and reports
// what it actually found, and the server renders that sentence. In Chrome and
// in `cargo tauri dev` it may work today; in a signed build it will say what
// stopped it. Neither is hard-coded.
import {analyse, band, createHold, meterFraction, toDb} from "../lib/meter.js"

// A processor that forwards raw frames to the main thread. Registered from a
// blob-free data: URL — `worklet.addModule` accepts one, and a separate asset
// would need a route and a CSP entry for a 12-line script.
const PROCESSOR = `
class TapProcessor extends AudioWorkletProcessor {
  process(inputs) {
    const channel = inputs[0] && inputs[0][0]
    if (channel && channel.length) this.port.postMessage(channel.slice(0))
    return true
  }
}
registerProcessor("tap", TapProcessor)
`

// V.7: all three of these are ON by default, all three are built for conference
// calls, and all three are TIME-VARYING — they change behaviour as the signal
// changes. autoGainControl is the sharpest: two takes of the same word a minute
// apart come back at different levels, so a cut-up splicing them has an audible
// jump at every seam. That is exactly the artefact `sound_assemble`'s normalize
// option exists to suppress, reintroduced upstream where nothing can remove it.
// noiseSuppression is nearly as bad — it gates and reshapes quiet passages,
// which is where word onsets and plosive closures live.
const CONSTRAINTS = {
  echoCancellation: false,
  noiseSuppression: false,
  autoGainControl: false,
  channelCount: 1,
}

export const VoiceRecorder = {
  mounted() {
    this.recording = false
    this.chunks = []
    this.hold = createHold()
    this.els = {
      record: this.el.querySelector('[data-role="record"]'),
      meter: this.el.querySelector('[data-role="meter"]'),
      peak: this.el.querySelector('[data-role="peak"]'),
      clip: this.el.querySelector('[data-role="clip"]'),
      format: this.el.querySelector('[data-role="format"]'),
      status: this.el.querySelector('[data-role="status"]'),
    }

    this.onClick = this.onClick.bind(this)
    this.els.record?.addEventListener("click", this.onClick)

    this.open()
  },

  destroyed() {
    this.els.record?.removeEventListener("click", this.onClick)
    this.close()
  },

  // The server re-renders this subtree's siblings, never its interior
  // (phx-update="ignore"), so the only thing to reconcile is whether the button
  // may be pressed — which depends on a word having been typed.
  updated() {
    this.paint()
  },

  // --- the stream -----------------------------------------------------------

  // THE METER RUNS BEFORE YOU ARM. V.6 calls this the single behaviour that
  // prevents most bad recordings: the operator sets their level while watching
  // the needle, without committing to a take. So the stream opens on mount and
  // the record button only decides whether frames are KEPT.
  async open() {
    if (!navigator.mediaDevices?.getUserMedia) {
      return this.report("unsupported")
    }

    try {
      const device = this.el.dataset.device
      const audio = device ? {...CONSTRAINTS, deviceId: {exact: device}} : CONSTRAINTS
      this.stream = await navigator.mediaDevices.getUserMedia({audio})
    } catch (error) {
      // A device pinned by id can vanish between enumeration and open. Retrying
      // with the default is better than reporting the whole feature denied,
      // because the two cases need different actions from the operator.
      try {
        this.stream = await navigator.mediaDevices.getUserMedia({audio: CONSTRAINTS})
      } catch (fallbackError) {
        return this.report("denied", fallbackError?.name || String(fallbackError))
      }
    }

    await this.listen()
    this.report("ready")
  },

  async listen() {
    // No sampleRate in the context options: V.7's policy is to capture at the
    // device's native rate and archive that master. Asking the browser to
    // resample on the way in is lossy and irreversible.
    this.context = new AudioContext()
    await this.context.audioWorklet.addModule(
      "data:text/javascript;base64," + btoa(PROCESSOR),
    )

    this.node = new AudioWorkletNode(this.context, "tap")
    this.node.port.onmessage = (event) => this.onFrames(event.data)
    this.context.createMediaStreamSource(this.stream).connect(this.node)

    // The worklet must reach a destination to be pulled, but its output must
    // never reach the speakers or the operator records their own monitor.
    const silence = this.context.createGain()
    silence.gain.value = 0
    this.node.connect(silence).connect(this.context.destination)

    this.describe()
  },

  // CONSTRAINTS ARE REQUESTS, NOT GUARANTEES (V.7). Verify with getSettings and
  // show the operator what actually happened — including a warning below
  // 32 kHz, which is where a Bluetooth headset dropped to HFP narrowband lands
  // and is close to the phone-quality audio this corpus is trying to escape.
  describe() {
    const track = this.stream?.getAudioTracks?.()[0]
    const settings = track?.getSettings?.() || {}
    const rate = settings.sampleRate || this.context?.sampleRate
    const applied = ["echoCancellation", "noiseSuppression", "autoGainControl"]
      .filter((key) => settings[key] === true)

    this.rate = Math.round(rate || 0)

    const parts = [track?.label || "input", `${this.rate} Hz`, "1 ch"]
    if (this.rate && this.rate < 32000) parts.push("⚠ narrowband")
    if (applied.length) parts.push(`⚠ ${applied.join(", ")} still on`)

    if (this.els.format) this.els.format.textContent = parts.join(" · ")
  },

  close() {
    this.stream?.getTracks?.().forEach((track) => track.stop())
    this.context?.close?.()
    this.stream = null
    this.context = null
    this.node = null
  },

  // --- frames ---------------------------------------------------------------

  onFrames(samples) {
    const {peak, clipped} = analyse(samples)
    this.hold.push(peak)
    this.paintMeter(peak, clipped)

    if (this.recording) this.chunks.push(samples)
  },

  paintMeter(peak, clipped) {
    const db = toDb(peak)
    const {hold, clipped: latched} = this.hold.value

    if (this.els.meter) {
      this.els.meter.style.width = `${(meterFraction(db) * 100).toFixed(1)}%`
      this.els.meter.dataset.band = band(db)
    }

    if (this.els.peak) {
      this.els.peak.textContent = `peak ${toDb(hold).toFixed(1)} dBFS`
    }

    // Latched, so a clip that lasted 40 ms is still visible when the take ends.
    if (this.els.clip && (clipped || latched)) {
      this.els.clip.classList.remove("hidden")
    }
  },

  // --- transport ------------------------------------------------------------

  onClick() {
    if (this.recording) this.stop()
    else this.start()
  },

  start() {
    if (this.el.dataset.armed !== "true") return
    this.chunks = []
    this.hold.reset()
    this.els.clip?.classList.add("hidden")
    this.recording = true
    this.paint()
  },

  stop() {
    this.recording = false
    this.paint()

    const samples = this.chunks.reduce((total, chunk) => total + chunk.length, 0)
    if (!samples) return this.say("Nothing was captured — the take was too short.")

    this.pushEvent("contribute_take", {
      pcm: this.encode(samples),
      sample_rate: this.rate,
    })
    this.chunks = []
  },

  // Float32 frames to base64, little-endian, matching what
  // Capture.Take.decode/2 reads. DataView with an explicit littleEndian flag
  // rather than Float32Array's native order: the two agree on every platform
  // this ships to, and stating it is cheaper than assuming it.
  encode(total) {
    const buffer = new ArrayBuffer(total * 4)
    const view = new DataView(buffer)
    let offset = 0

    for (const chunk of this.chunks) {
      for (let i = 0; i < chunk.length; i++, offset += 4) {
        view.setFloat32(offset, chunk[i], true)
      }
    }

    const bytes = new Uint8Array(buffer)
    let binary = ""
    // Chunked, because String.fromCharCode(...bytes) blows the argument limit
    // on anything longer than about a second.
    for (let i = 0; i < bytes.length; i += 8192) {
      binary += String.fromCharCode(...bytes.subarray(i, i + 8192))
    }
    return btoa(binary)
  },

  // --- painting -------------------------------------------------------------

  paint() {
    const armed = this.el.dataset.armed === "true"
    if (!this.els.record) return

    this.els.record.disabled = !armed && !this.recording
    this.els.record.textContent = this.recording ? "■ Stop" : "● Record"
  },

  say(message) {
    if (this.els.status) this.els.status.textContent = message
  },

  report(state, detail) {
    this.pushEvent("contribute", {do: "capability", state, detail})
  },
}
