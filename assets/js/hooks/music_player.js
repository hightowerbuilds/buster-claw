// The dock music player's bridge between LiveView and a real <audio> element.
//
// The element is phx-update="ignore", so the server never touches it — this
// hook owns it entirely and drives it from data-* attributes on the hook root.
// That separation is load-bearing: if LiveView patched the element's src on an
// unrelated re-render, playback would restart from zero, which is exactly how a
// player like this ends up "randomly jumping to the beginning".
//
// Direction of truth: the server decides WHAT should play; the element decides
// what IS playing, and reports back (playing/paused/ended/position/duration).
import {isTypingContext} from "../lib/keys.js"

export const MusicPlayer = {
  mounted() {
    this.audio = this.el.querySelector("#bc-music-audio")
    this.currentSrc = null
    this.lastSeekId = this.el.getAttribute("data-seek-id")
    this.lastReport = 0

    this.audio.addEventListener("ended", () => this.pushEvent("ended", {}))

    this.audio.addEventListener("play", () => this.pushEvent("playing", {playing: true}))
    this.audio.addEventListener("pause", () => {
      // A pause fired because the track ended is not a user pause; "ended"
      // already advanced the queue, and reporting paused here would fight it.
      if (!this.audio.ended) this.pushEvent("playing", {playing: false})
    })

    this.audio.addEventListener("loadedmetadata", () => {
      if (Number.isFinite(this.audio.duration)) {
        this.pushEvent("duration", {seconds: this.audio.duration})
      }
    })

    this.audio.addEventListener("error", () => {
      // Missing file, unsupported codec, or a decode failure. Tell the server so
      // it can move on rather than sit on a track that will never play.
      if (this.currentSrc) this.pushEvent("error", {src: this.currentSrc})
    })

    // Keyboard transport, YouTube-style: Space toggles, media keys map to
    // their names. Guarded three ways — no track loaded means keys pass
    // through untouched (Space must still scroll an idle page); anything
    // typed into an input/textarea/select/contenteditable is never ours (this
    // also covers xterm, whose hidden helper is a textarea); and key repeat is
    // dropped so holding Space doesn't strobe play/pause.
    this.onKey = (e) => {
      if (!this.currentSrc || e.repeat) return
      if (isTypingContext(e.target)) return
      if (e.code === "Space" || e.code === "MediaPlayPause") {
        e.preventDefault()
        this.pushEvent("toggle", {})
      } else if (e.code === "MediaTrackNext") {
        this.pushEvent("next", {})
      } else if (e.code === "MediaTrackPrevious") {
        this.pushEvent("previous", {})
      }
    }
    window.addEventListener("keydown", this.onKey)

    // Position is reported on a throttle, not per frame: the server only needs
    // it for a readout, and per-frame traffic over the socket would be waste.
    this.audio.addEventListener("timeupdate", () => {
      const every = parseInt(this.el.getAttribute("data-report-ms") || "5000", 10)
      const now = Date.now()
      if (now - this.lastReport >= every) {
        this.lastReport = now
        this.pushEvent("position", {seconds: this.audio.currentTime})
      }
    })

    this.apply()
  },

  updated() {
    this.apply()
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKey)
    // Sticky LiveViews are not supposed to be torn down mid-session, but if one
    // is, leave silence behind rather than an orphaned element still playing.
    try {
      this.audio.pause()
      this.audio.removeAttribute("src")
      this.audio.load()
    } catch (_e) {}
  },

  apply() {
    const src = this.el.getAttribute("data-src")
    const shouldPlay = this.el.getAttribute("data-playing") === "true"
    const volume = parseInt(this.el.getAttribute("data-volume") || "80", 10)

    // Only touch src when it ACTUALLY changed. Assigning the same URL reloads
    // the resource and restarts playback, so this comparison is the difference
    // between a working player and one that stutters on every re-render.
    if (src !== this.currentSrc) {
      this.currentSrc = src
      if (src) {
        this.audio.src = src
        this.audio.load()
      } else {
        this.audio.pause()
        this.audio.removeAttribute("src")
        this.audio.load()
      }
    }

    this.audio.volume = Math.max(0, Math.min(100, volume)) / 100

    // A seek is identified by a counter, not by the target position: seeking
    // back to a position you already sought to must still move the playhead.
    const seekId = this.el.getAttribute("data-seek-id")
    if (seekId !== this.lastSeekId) {
      this.lastSeekId = seekId
      const target = parseFloat(this.el.getAttribute("data-seek-to"))
      if (Number.isFinite(target)) {
        try {
          this.audio.currentTime = target
        } catch (_e) {
          // Seeking before metadata is loaded throws; the position will be
          // applied by whatever the user does next rather than crashing here.
        }
      }
    }

    if (!src) return

    if (shouldPlay && this.audio.paused) {
      // play() rejects when the browser has not seen a user gesture yet. That
      // is a real state, not an error to swallow silently — tell the server the
      // element is not playing so the UI stops claiming that it is.
      const started = this.audio.play()
      if (started && typeof started.catch === "function") {
        started.catch(() => this.pushEvent("playing", {playing: false}))
      }
    } else if (!shouldPlay && !this.audio.paused) {
      this.audio.pause()
    }
  },
}
