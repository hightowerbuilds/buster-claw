// Homepage chat: keep the transcript scrolled to the newest message, and make
// Enter submit the message (Shift+Enter inserts a newline). The textarea is
// cleared optimistically on submit; the user echo comes back over PubSub.
export const AgentChat = {
  mounted() {
    this.log = this.el.querySelector("[data-chat-log]")
    this.input = this.el.querySelector("[data-chat-input]")
    this.form = this.el.querySelector("[data-chat-form]")
    this.handle = this.el.querySelector("[data-resize-handle]")
    this.applyHeight()
    this.scrollToBottom()

    this.onKeydown = (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        if (this.input.value.trim() !== "") {
          this.form.requestSubmit()
          this.input.value = ""
        }
      }
    }
    this.onSubmit = () => {
      // Clear after the framework has serialized the form values.
      requestAnimationFrame(() => {
        this.input.value = ""
      })
    }
    // Esc stops the model while a run is in flight (mirrors the header Stop
    // button). Gated on data-running so it doesn't hijack Escape when idle.
    this.onEscape = (e) => {
      if (e.key === "Escape" && this.el.dataset.running === "true") {
        e.preventDefault()
        this.pushEvent("cut_run", {})
      }
    }
    window.addEventListener("keydown", this.onEscape)

    // Drag the bottom handle to resize the chat height. Persisted in
    // localStorage and re-applied on updated() (LiveView patches would
    // otherwise drop the inline height on the next render).
    this.onHandleDown = (e) => {
      e.preventDefault()
      this.dragging = true
      this.dragStartY = e.clientY
      this.dragStartH = this.el.offsetHeight
      window.addEventListener("pointermove", this.onHandleMove)
      window.addEventListener("pointerup", this.onHandleUp)
      document.body.style.userSelect = "none"
      document.body.style.cursor = "ns-resize"
    }
    this.onHandleMove = (e) => {
      this.el.style.height = this.clampHeight(this.dragStartH + (e.clientY - this.dragStartY)) + "px"
    }
    this.onHandleUp = () => {
      this.dragging = false
      window.removeEventListener("pointermove", this.onHandleMove)
      window.removeEventListener("pointerup", this.onHandleUp)
      document.body.style.userSelect = ""
      document.body.style.cursor = ""
      const h = parseInt(this.el.style.height, 10)
      if (!isNaN(h)) localStorage.setItem("bc:chat-height", String(h))
    }

    this.input.addEventListener("keydown", this.onKeydown)
    this.form.addEventListener("submit", this.onSubmit)
    this.handle?.addEventListener("pointerdown", this.onHandleDown)
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
    this.applyHeight()
    this.scrollToBottom()
  },
  destroyed() {
    this.input.removeEventListener("keydown", this.onKeydown)
    this.form.removeEventListener("submit", this.onSubmit)
    this.handle?.removeEventListener("pointerdown", this.onHandleDown)
    window.removeEventListener("keydown", this.onEscape)
    window.removeEventListener("pointermove", this.onHandleMove)
    window.removeEventListener("pointerup", this.onHandleUp)
    // If destroyed mid-drag, onHandleUp never fired — restore the body styles it
    // would have reset, or the page is left with text selection disabled and a
    // stuck ns-resize cursor.
    if (this.dragging) {
      document.body.style.userSelect = ""
      document.body.style.cursor = ""
    }
  },
  scrollToBottom() {
    if (this.log) this.log.scrollTop = this.log.scrollHeight
  },
  clampHeight(h) {
    const min = 240
    const max = Math.round(window.innerHeight * 0.9)
    return Math.max(min, Math.min(max, h))
  },
  applyHeight() {
    if (this.dragging) return
    const saved = parseInt(localStorage.getItem("bc:chat-height"), 10)
    if (!isNaN(saved)) this.el.style.height = this.clampHeight(saved) + "px"
  },
}

// Live chat "thinking" timer. While data-state="running" it ticks up from the
// moment it mounted (no server round-trips); when the first token lands the
// server flips data-state="done" with the authoritative data-ms, and we freeze
// the label to that. The element only exists while a turn is in flight, so
// mount/destroy bound the timer's lifetime.
export const ThinkingTimer = {
  mounted() {
    this.labelEl = this.el.querySelector("[data-thinking-label]")
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
      this.setLabel("Thought " + this.fmt(isNaN(ms) ? 0 : ms))
    } else {
      if (this.startedAt == null) this.startedAt = performance.now()
      if (!this.timer) this.timer = setInterval(() => this.tick(), 100)
      this.tick()
    }
  },
  tick() {
    if (this.startedAt != null) this.setLabel("Thinking " + this.fmt(performance.now() - this.startedAt))
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
