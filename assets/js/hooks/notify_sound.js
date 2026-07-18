// NotifySound — plays the workspace chime when a notification fires. The server
// (NotifyLive) pushes "notify:play-sound"; we play /notify/sound, the operator's
// audio file from <workspace>/sounds/. No OS notification involved.
//
// Webviews gate programmatic playback behind a prior user gesture, so we "unlock"
// the audio element on the first pointer/key event (the user has almost always
// clicked something — set a timer, navigated — before an alarm fires). If no
// sound is configured, /notify/sound 404s and play() rejects; we swallow it.
export const NotifySound = {
  mounted() {
    this.audio = new Audio("/notify/sound")
    this.audio.preload = "auto"
    this.unlocked = false

    this.unlock = () => {
      // Within the gesture, kick a muted play/pause so later programmatic plays
      // are allowed. Ignore failures (no sound configured, etc.).
      this.audio.muted = true
      this.audio
        .play()
        .then(() => {
          this.audio.pause()
          this.audio.currentTime = 0
          this.audio.muted = false
          this.unlocked = true
        })
        .catch(() => {
          this.audio.muted = false
        })
    }
    window.addEventListener("pointerdown", this.unlock, {once: true})
    window.addEventListener("keydown", this.unlock, {once: true})

    this.handleEvent("notify:play-sound", () => this.play())
  },

  destroyed() {
    window.removeEventListener("pointerdown", this.unlock, {once: true})
    window.removeEventListener("keydown", this.unlock, {once: true})
    this.audio?.pause()
    this.audio = null
  },

  play() {
    if (!this.audio) return
    try {
      this.audio.currentTime = 0
    } catch (_e) {
      // currentTime can throw before metadata loads — ignore and let play() seek.
    }
    this.audio.play().catch(() => {
      // Autoplay blocked (no prior gesture) or no sound configured — stay silent.
    })
  },
}
