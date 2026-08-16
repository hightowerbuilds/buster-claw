// Hearing the library — a take, or a sentence built from takes
// (STUDIO_ROADMAP VI.1, pane 2).
//
// VI.1 recorded this pane as deliberately absent because it "needs a route
// serving a take's audio, which is its own surface". That was wrong in a useful
// way: `/studio/file/:name` has served any studio source with byte ranges since
// the Studio shipped, and a TAKE IS A SLICE OF A SOURCE — start_ms to end_ms
// inside a file the browser can already fetch. What was missing was never a
// route. It was this arithmetic.
//
// No blob: URLs and no <audio> element. `default-src 'self'` is in force with no
// media-src, so blob: media is refused — `studio_audition.js` documents the same
// constraint and reaches the same shape: fetch, decode, schedule on an
// AudioContext. This is the smaller sibling of that hook; it plays one range at
// a time rather than an arrangement.
//
// Decoded buffers are cached per source, because auditioning is inherently
// repetitive — you play four takes of the same word from the same two files,
// and re-decoding each time would put a hitch exactly where the comparison is.

export const VoiceAudition = {
  mounted() {
    // Shared across every button inside this section. An AudioBuffer is a PCM
    // container and is not bound to the context that decoded it, so the cache
    // survives the context being closed and reopened.
    this.buffers = new Map()
    this.onClick = this.onClick.bind(this)
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.stop()
    this.context?.close?.()
    this.el.removeEventListener("click", this.onClick)
  },

  onClick(event) {
    const button = event.target.closest("[data-play]")
    if (!button || !this.el.contains(button)) return

    event.preventDefault()
    this.play(button)
  },

  async play(button) {
    const {source, start, end, version} = button.dataset
    if (!source) return
    this.stop()

    try {
      const buffer = await this.buffer(source, version)
      const context = this.audio()

      // A missing `data-start` means the whole file, which is what a built
      // sentence is. Milliseconds in the DOM, seconds in WebAudio.
      const from = start === undefined ? 0 : Number(start) / 1000
      const to = end === undefined ? buffer.duration : Number(end) / 1000
      const span = Math.max(to - from, 0)

      if (!(span > 0)) return this.mark(null)

      const node = context.createBufferSource()
      node.buffer = buffer
      node.connect(context.destination)
      node.onended = () => this.mark(null)
      node.start(0, from, span)

      this.node = node
      this.mark(button)
    } catch (error) {
      // A source can vanish between render and click — a Finder delete, or a
      // preview overwritten by a newer build. Silence with a marker cleared is
      // the honest outcome; there is nothing for the operator to fix.
      this.mark(null)
      console.warn("[VoiceAudition]", source, error)
    }
  },

  stop() {
    if (!this.node) return
    // The handler would clear the marker for a take that is no longer playing.
    this.node.onended = null
    try {
      this.node.stop()
    } catch (_error) {
      // Already stopped; nothing to do.
    }
    this.node = null
    this.mark(null)
  },

  audio() {
    if (!this.context || this.context.state === "closed") {
      this.context = new AudioContext()
    }
    // Autoplay policy suspends a context created before a gesture; every path
    // here starts from a click, so resuming is safe and is what makes the first
    // press audible.
    if (this.context.state === "suspended") this.context.resume()
    return this.context
  },

  // Keyed on source AND version, because the sentence preview OVERWRITES one
  // fixed filename on every build. Caching on the name alone would replay the
  // previous sentence from the same URL — silently, and convincingly, since it
  // is real audio of a real phrase. Takes carry no version and cache forever,
  // which is correct: a recording is never overwritten.
  async buffer(source, version) {
    const key = version === undefined ? source : `${source}@${version}`
    const cached = this.buffers.get(key)
    if (cached) return cached

    const url = `/studio/file/${encodeURIComponent(source)}`
    const response = await fetch(version === undefined ? url : `${url}?v=${version}`)
    if (!response.ok) throw new Error(`${response.status}`)

    const bytes = await response.arrayBuffer()
    const buffer = await this.audio().decodeAudioData(bytes)
    this.buffers.set(key, buffer)
    return buffer
  },

  // Purely visual, and deliberately not a server round trip: which take is
  // sounding right now is client state that changes faster than a LiveView
  // patch and means nothing once it stops.
  //
  // Marks the BUTTON, not the source. Four takes of one word commonly come from
  // the same file, so matching on `data-source` would light all four and the
  // highlight would stop meaning "this one".
  mark(playing) {
    this.el.querySelectorAll("[data-play]").forEach((button) => {
      button.classList.toggle("text-primary", button === playing)
    })
  },
}
