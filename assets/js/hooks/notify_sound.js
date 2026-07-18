// NotifySound — plays a workspace sound when a notification fires. The server
// (NotifyLive) pushes "notify:play-sound" with the routed library sound's name
// (Settings → Notify decides which sound each event gets); we play
// /notify/sound/<name>, falling back to /notify/sound (the resolved default)
// when no name arrives. No OS notification involved.
//
// Webviews gate programmatic playback behind a prior user gesture, so we
// "unlock" a single reusable audio element on the first pointer/key event (the
// user has almost always clicked something — set a timer, navigated — before an
// alarm fires). Swapping `src` on the unlocked element keeps its playback
// permission, which is why we reuse one element instead of one per sound. If no
// sound is configured the URL 404s and play() rejects; we swallow it.
export const NotifySound = {
  mounted() {
    this.currentUrl = this.soundUrl(null)
    this.audio = new Audio(this.currentUrl)
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

    this.handleEvent("notify:play-sound", ({name}) => this.play(name))
  },

  destroyed() {
    window.removeEventListener("pointerdown", this.unlock, {once: true})
    window.removeEventListener("keydown", this.unlock, {once: true})
    this.audio?.pause()
    this.audio = null
  },

  soundUrl(name) {
    return name ? `/notify/sound/${encodeURIComponent(name)}` : "/notify/sound"
  },

  play(name) {
    if (!this.audio) return
    const url = this.soundUrl(name)
    if (url !== this.currentUrl) {
      this.currentUrl = url
      this.audio.src = url
    }
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

// SoundPreview — auditions library sounds from Settings → Notify. A delegated
// click listener on the panel: any descendant button carrying data-preview-url
// plays that file. Clicks are user gestures, so no unlock dance is needed; a
// new preview stops the previous one so rapid clicking doesn't stack audio.
export const SoundPreview = {
  mounted() {
    this.current = null
    this.onClick = (event) => {
      const button = event.target.closest("[data-preview-url]")
      if (!button || !this.el.contains(button)) return
      this.current?.pause()
      this.current = new Audio(button.dataset.previewUrl)
      this.current.play().catch(() => {})
    }
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    this.current?.pause()
    this.current = null
  },
}
