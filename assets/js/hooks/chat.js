// Homepage chat: keep the transcript scrolled to the newest message, and make
// Enter submit the message (Shift+Enter inserts a newline). The textarea is
// cleared optimistically on submit; the user echo comes back over PubSub.
export const AgentChat = {
  mounted() {
    this.log = this.el.querySelector("[data-chat-log]")
    this.input = this.el.querySelector("[data-chat-input]")
    this.form = this.el.querySelector("[data-chat-form]")
    this.scrollToBottom()

    // Enter/Shift+Enter/chord handling now lives in the `Composer` hook on the
    // form itself, shared with Trading's windows. It was duplicated here and in
    // chat_window.js, and a third rule was about to be added to both.
    // Esc stops the model while a run is in flight (mirrors the header Stop
    // button). Gated on data-running so it doesn't hijack Escape when idle.
    this.onEscape = (e) => {
      if (e.key === "Escape" && this.el.dataset.running === "true") {
        e.preventDefault()
        this.pushEvent("cut_run", {})
      }
    }
    window.addEventListener("keydown", this.onEscape)

    // Voice input lives in its own reusable `Mic` hook on the mic button.

    // Prefill the composer from elsewhere in the app (e.g. the corner widget's
    // "Email <contact>" button): drop in the template, focus, and put the cursor
    // at the end so the user just types their message. The input event lets any
    // auto-resize react. Received even when the hook just mounted because the
    // Chat sub-tab was switched on in the same render.
    this.handleEvent("bc:chat_prefill", ({text}) => {
      if (typeof text !== "string") return
      this.input.value = text
      this.input.focus()
      const end = this.input.value.length
      this.input.setSelectionRange(end, end)
      this.input.dispatchEvent(new Event("input", {bubbles: true}))
    })
  },
  updated() {
    this.scrollToBottom()
  },
  destroyed() {
    window.removeEventListener("keydown", this.onEscape)
  },
  scrollToBottom() {
    if (this.log) this.log.scrollTop = this.log.scrollHeight
  },
}

// Live "something slow is happening" timer. While data-state="running" it ticks
// up client-side (no server round-trips); when the work lands the server flips
// data-state="done" with the authoritative data-ms and we freeze the label to
// that. The element only exists while the work is in flight, so mount/destroy
// bound the timer's lifetime.
//
// Two call sites, and the differences between them are data attributes rather
// than a second copy of this — the same move `voice_recorder.js` made when the
// Vox2B recorder needed its event names (09-03):
//
//   * data-label-running / data-label-done — the chat says "Thinking"/"Thought",
//     Vox2B says "Making"/"Made". Defaulted, so the chat's markup is unchanged.
//   * data-elapsed-ms — how long the work had ALREADY been running when this
//     element mounted. The chat needs no offset: its chip exists for the whole
//     turn. Vox2B does, because the homepage discards the tab's panel on a tab
//     switch — without this, wandering off to Chat and back would remount the
//     timer and cheerfully report "0.2s" into a four-minute render. Read ONCE in
//     mounted() on purpose: re-reading it on every update would make the label
//     jump every time an unrelated assign changed.
export const ThinkingTimer = {
  mounted() {
    this.labelEl = this.el.querySelector("[data-thinking-label]")
    const offset = parseInt(this.el.dataset.elapsedMs, 10)
    this.offsetMs = isNaN(offset) ? 0 : Math.max(0, offset)
    this.render()
  },
  updated() {
    this.render()
  },
  destroyed() {
    this.stop()
  },
  render() {
    if (this.el.dataset.state === "done") {
      this.stop()
      const ms = parseInt(this.el.dataset.ms, 10)
      this.setLabel(this.doneLabel() + " " + this.fmt(isNaN(ms) ? 0 : ms))
    } else {
      if (this.startedAt == null) this.startedAt = performance.now()
      if (!this.timer) this.timer = setInterval(() => this.tick(), 100)
      this.tick()
    }
  },
  tick() {
    if (this.startedAt == null) return
    const ms = (this.offsetMs || 0) + performance.now() - this.startedAt
    this.setLabel(this.runningLabel() + " " + this.fmt(ms))
  },
  runningLabel() {
    return this.el.dataset.labelRunning || "Thinking"
  },
  doneLabel() {
    return this.el.dataset.labelDone || "Thought"
  },
  stop() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  },
  setLabel(text) {
    if (this.labelEl) this.labelEl.textContent = text
  },
  fmt(ms) {
    return (Math.max(0, ms) / 1000).toFixed(1) + "s"
  },
}

// Drag-reorder the chat queue (the Tetris rail). Reorders the DOM optimistically
// during the drag, then pushes the new id order to the server, which re-broadcasts
// the canonical queue — so the rail snaps to the authoritative order on drop.
export const QueueRail = {
  mounted() {
    this.dragId = null
    this.onDragStart = (e) => {
      const li = e.target.closest("[data-id]")
      if (!li) return
      this.dragId = li.dataset.id
      if (e.dataTransfer) e.dataTransfer.effectAllowed = "move"
      // Defer so the drag image is captured before we dim the source.
      requestAnimationFrame(() => li.classList.add("opacity-40"))
    }
    this.onDragOver = (e) => {
      if (this.dragId == null) return
      e.preventDefault()
      const over = e.target.closest("[data-id]")
      const dragged = this.el.querySelector(`[data-id="${this.dragId}"]`)
      if (!over || !dragged || over === dragged) return
      const rect = over.getBoundingClientRect()
      const after = e.clientY - rect.top > rect.height / 2
      this.el.insertBefore(dragged, after ? over.nextSibling : over)
    }
    this.onDrop = (e) => e.preventDefault()
    this.onDragEnd = () => {
      const dragged = this.dragId && this.el.querySelector(`[data-id="${this.dragId}"]`)
      if (dragged) dragged.classList.remove("opacity-40")
      const ids = [...this.el.querySelectorAll("[data-id]")].map((li) => li.dataset.id)
      this.dragId = null
      this.pushEvent("reorder_queue", { ids })
    }
    this.el.addEventListener("dragstart", this.onDragStart)
    this.el.addEventListener("dragover", this.onDragOver)
    this.el.addEventListener("drop", this.onDrop)
    this.el.addEventListener("dragend", this.onDragEnd)
  },
  destroyed() {
    this.el.removeEventListener("dragstart", this.onDragStart)
    this.el.removeEventListener("dragover", this.onDragOver)
    this.el.removeEventListener("drop", this.onDrop)
    this.el.removeEventListener("dragend", this.onDragEnd)
  },
}
